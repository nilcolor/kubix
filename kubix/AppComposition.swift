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

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = home.appendingPathComponent("Library/Application Support/Kubix", isDirectory: true)
        let settings = AppAuthSettingsStore(directory: directory)
        let environment = ProcessInfo.processInfo.environment
        let resolver = PluginResolver(environment: environment, store: settings)
        let provider = CredentialProvider(resolver: resolver)
        let login = AWSLoginService()
        let authentication = AuthenticationService(provider: provider, login: login)
        // The immutable context warning is also rendered beside every session and the connect form.
        registry = ContextTransportRegistry(credentials: authentication, warning: { _ in })
        let exec = ExecService(transports: { [registry] in try await registry.transport(for: $0) })
        let factory = ExecSurfaceFactory()
        store = AppStore()
        actions = AppActions(
            store: store, exec: exec, authentication: authentication, surfaces: factory, browser: BrowserLauncher(),
            configurations: AppConfigurationLoader(
                loader: KubeconfigLoader(environment: environment, homeDirectory: home), settings: settings
            )
        )
        factory.closeSession = { [weak actions] id in actions?.closeShell(id) }
        Self.active = self
    }

    func shutdown() async {
        await actions.shutdownAndWait()
        await registry.shutdown()
    }
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
