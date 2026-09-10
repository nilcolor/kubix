import AppKit
import KubixCore
import KubixRuntime

@MainActor
final class AppComposition {
    static let shared = AppComposition()
    private(set) static var active: AppComposition?
    let store: AppStore
    let actions: AppActions
    private let registry: ContextTransportRegistry
    #if DEBUG
    let validationProcess = ExecValidationProcess()
    let validationTransportFactory = ExecValidationTransportFactory()
    let isolatedVault: IsolatedAWSVaultRunner?
    #endif

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = home.appendingPathComponent("Library/Application Support/Kubix", isDirectory: true)
        let settings = AppAuthSettingsStore(directory: directory)
        let environment = ProcessInfo.processInfo.environment
        let resolver = PluginResolver(environment: environment, store: settings)
        #if DEBUG
        isolatedVault = AWSVaultIsolationValidation.root.map {
            IsolatedAWSVaultRunner(parent: $0.appendingPathComponent(".build"), profile: "synthetic-profile")
        }
        let process: any ProcessRunning
        if let isolatedVault { process = isolatedVault } else {
            process = ExecLiveValidation.isEnabled ? validationProcess : ProcessRunner()
        }
        let provider = CredentialProvider(resolver: resolver, runner: CredentialRunner(process: process))
        #else
        let provider = CredentialProvider(resolver: resolver)
        #endif
        let login = AWSLoginService()
        let authentication = AuthenticationService(provider: provider, login: login)
        // The immutable context warning is also rendered beside every session and the connect form.
        #if DEBUG
        if ExecLiveValidation.isEnabled {
            registry = ContextTransportRegistry(factory: { [validationTransportFactory] context in
                try await URLSessionTransport(
                    context: context, credentials: authentication, factory: validationTransportFactory, warning: { _ in }
                )
            })
        } else { registry = ContextTransportRegistry(credentials: authentication, warning: { _ in }) }
        #else
        registry = ContextTransportRegistry(credentials: authentication, warning: { _ in })
        #endif
        let transports: ExecService.TransportFactory = { [registry] in try await registry.transport(for: $0) }
        #if DEBUG
        let exec = ExecLiveValidation.bridgeRoot.map { ExecService(transports: transports, validationRoot: $0) }
            ?? ExecService(transports: transports)
        #else
        let exec = ExecService(transports: transports)
        #endif
        let factory = ExecSurfaceFactory()
        store = AppStore()
        actions = AppActions(
            store: store, exec: exec, authentication: authentication, surfaces: factory, browser: BrowserLauncher(),
            configurations: AppConfigurationLoader(
                loader: KubeconfigLoader(environment: environment, homeDirectory: home), settings: settings
            ), pods: Self.podWatcher(transports: transports)
        )
        factory.closeSession = { [weak actions] id in actions?.closeShell(id) }
        Self.active = self
    }

    private static func podWatcher(transports: @escaping ExecService.TransportFactory) -> (any PodWatching)? {
        #if DEBUG
        // Existing constrained exec/auth validation must never grow a discovery request implicitly.
        if ExecLiveValidation.isEnabled || AWSVaultIsolationValidation.root != nil { return nil }
        #endif
        return WatchService(transports: transports)
    }

    func shutdown() async {
        await actions.shutdownAndWait()
        await registry.shutdown()
        #if DEBUG
        try? await isolatedVault?.cleanup()
        #endif
    }

    #if DEBUG
    func validationTransport(for context: ResolvedContext) async throws -> any Transport {
        try await registry.transport(for: context)
    }
    #endif
}

private actor AppAuthSettingsStore: AuthSettingsStoring {
    let directory: URL
    let file: FileAuthSettingsStore

    init(directory: URL) {
        self.directory = directory
        file = FileAuthSettingsStore(url: directory.appendingPathComponent("auth-settings.json"))
    }

    func load() async throws -> AuthSettings { try await file.load() }
    func save(_ settings: AuthSettings) async throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await file.save(settings)
        } catch { throw AuthenticationError.settingsUnavailable }
    }
}

@MainActor
private final class ExecSurfaceFactory: TerminalSurfaceCreating {
    var closeSession: ((UUID) -> Void)?

    func makeSurface(
        sessionID: UUID, target: ExecTarget, endpoint: ExecBridgeEndpoint,
        onChildExit: @escaping @MainActor @Sendable () -> Void
    ) throws -> any TerminalSurface {
        guard GhosttyApp.shared.app != nil, let executable = Bundle.main.executableURL else { throw ExecFailure.surface }
        let configuration = try TerminalConfiguration.bridge(executablePath: executable.path, endpoint: endpoint)
        let view = GhosttySurfaceView(configuration: configuration)
        view.onClose = onChildExit
        view.onFailure = onChildExit
        view.onWindowClose = { [weak self] in self?.closeSession?(sessionID) }
        return view
    }
}
