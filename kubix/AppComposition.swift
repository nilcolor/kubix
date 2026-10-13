import AppKit
import KubixCore
import KubixRuntime

@MainActor
final class AppComposition {
    static let shared = AppComposition()
    private(set) static var active: AppComposition?
    let store: AppStore
    let actions: AppActions
    private let registry: ContextTransportRegistry?
    #if DEBUG
    let validationProcess = ExecValidationProcess()
    let validationTransportFactory = ExecValidationTransportFactory()
    let isolatedVault: IsolatedAWSVaultRunner?
    let podValidation: PodBrowsingFixture?
    let validationPods: ExecLivePodWatcher?
    #endif

    private convenience init() {
        #if DEBUG
        // Select the closed synthetic world before constructing any user configuration/auth adapters.
        if PodBrowsingValidation.isEnabled {
            self.init(fixture: PodBrowsingFixture())
            return
        }
        #endif
        self.init(live: ())
    }

    private init(live: Void) {
        #if DEBUG
        podValidation = nil
        #endif
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support/Kubix", isDirectory: true)
        let settings = AppAuthSettingsStore(directory: support)
        let environment = ProcessInfo.processInfo.environment
        let resolver = PluginResolver(environment: environment, store: settings)
        #if DEBUG
        isolatedVault = AWSVaultIsolationValidation.root.map {
            IsolatedAWSVaultRunner(parent: $0.appendingPathComponent(".build"), profile: AWSVaultIsolationValidation.profile)
        }
        let fallback: any ProcessRunning = ExecLiveValidation.isEnabled ? validationProcess : ProcessRunner()
        let process: any ProcessRunning = isolatedVault ?? fallback
        let provider = CredentialProvider(resolver: resolver, runner: CredentialRunner(process: process))
        #else
        let provider = CredentialProvider(resolver: resolver)
        #endif
        // The interactive login shell can take seconds to load version managers; start reading PATH
        // now so that cost is spent while the window draws, not inside the user's first Connect.
        Task { await resolver.warmBaseline() }
        let authentication = AuthenticationService(provider: provider, login: AWSLoginService())
        // The immutable context warning is also rendered beside every session and the context picker.
        #if DEBUG
        registry = Self.transportRegistry(authentication: authentication, factory: validationTransportFactory)
        #else
        registry = ContextTransportRegistry(credentials: authentication, warning: { _ in })
        #endif
        let transports = Self.transports(registry)
        let lists: (any ResourceWatching)?
        #if DEBUG
        validationPods = ExecLiveValidation.isEnabled ? ExecLivePodWatcher(transports: transports, integrated: ExecLiveValidation.isAcceptance) : nil
        if let validationPods { lists = validationPods } else { lists = Self.listWatcher(transports: transports) }
        #else
        lists = Self.listWatcher(transports: transports)
        #endif
        let factory = ExecSurfaceFactory()
        store = AppStore()
        actions = AppActions(
            store: store, exec: Self.execService(transports: transports), authentication: authentication,
            surfaces: factory, browser: BrowserLauncher(),
            configurations: AppConfigurationLoader(
                loader: KubeconfigLoader(environment: environment, homeDirectory: home), settings: settings
            ), lists: lists, podDetails: PodDetailsService(transports: transports),
            deploymentDetails: DeploymentDetailsService(transports: transports),
            deploymentPods: DeploymentPodService(transports: transports),
            podDeleter: PodDeleteService(transports: transports), logs: LogService(transports: transports),
            probe: Self.clusterProbe(transports: transports),
            namespaces: Self.namespaceListing(transports: transports),
            metrics: Self.metricsListing(transports: transports)
        )
        factory.closeSession = { [weak actions] id in actions?.closeShell(id) }
        Self.active = self
    }

    private static func transports(_ registry: ContextTransportRegistry?) -> ExecService.TransportFactory {
        #if DEBUG
        let acceptance = ExecLiveValidation.isAcceptance
        #endif
        return { context in
            guard let registry else { throw APIError.invalidRequest }
            #if DEBUG
            if acceptance {
                guard context.name == ExecLiveDiscovery.context else { throw APIError.invalidRequest }
                return ExecLiveScopedTransport(underlying: try await registry.transport(for: context))
            }
            #endif
            return try await registry.transport(for: context)
        }
    }

    private static func clusterProbe(transports: @escaping ExecService.TransportFactory) -> (any ClusterProbing)? {
        #if DEBUG
        // The constrained exec/auth drivers must not gain an unnamespaced request implicitly.
        if ExecLiveValidation.isEnabled || AuthLoginValidation.isEnabled || AWSVaultIsolationValidation.root != nil { return nil }
        #endif
        return ClusterProbeService(transports: transports)
    }

    private static func namespaceListing(
        transports: @escaping ExecService.TransportFactory
    ) -> (any NamespaceListing)? {
        #if DEBUG
        // The constrained exec/auth drivers must not gain an unnamespaced request implicitly.
        if ExecLiveValidation.isEnabled || AuthLoginValidation.isEnabled || AWSVaultIsolationValidation.root != nil { return nil }
        #endif
        return NamespaceListService(transports: transports)
    }

    private static func metricsListing(
        transports: @escaping ExecService.TransportFactory
    ) -> (any PodMetricsListing)? {
        #if DEBUG
        // The constrained exec/auth drivers must not gain a polled request implicitly.
        if ExecLiveValidation.isEnabled || AuthLoginValidation.isEnabled || AWSVaultIsolationValidation.root != nil { return nil }
        #endif
        return PodMetricsService(transports: transports)
    }

    private static func listWatcher(transports: @escaping ExecService.TransportFactory) -> (any ResourceWatching)? {
        #if DEBUG
        // Existing constrained exec/auth validation must never grow a discovery request implicitly.
        if ExecLiveValidation.isEnabled || AuthLoginValidation.isEnabled || AWSVaultIsolationValidation.root != nil { return nil }
        #endif
        return WatchService(transports: transports)
    }

    private static func execService(transports: @escaping ExecService.TransportFactory) -> ExecService {
        #if DEBUG
        if let root = ExecLiveValidation.bridgeRoot { return ExecService(transports: transports, validationRoot: root) }
        #endif
        return ExecService(transports: transports)
    }

    func shutdown() async {
        await actions.shutdownAndWait()
        await registry?.shutdown()
        #if DEBUG
        try? await isolatedVault?.cleanup()
        #endif
    }

    #if DEBUG
    private static func transportRegistry(
        authentication: AuthenticationService, factory: ExecValidationTransportFactory
    ) -> ContextTransportRegistry {
        if ExecLiveValidation.isEnabled {
            return ContextTransportRegistry(factory: { context in
                try await URLSessionTransport(context: context, credentials: authentication, factory: factory, warning: { _ in })
            })
        }
        return ContextTransportRegistry(credentials: authentication, warning: { _ in })
    }

    private init(fixture: PodBrowsingFixture) {
        podValidation = fixture
        validationPods = nil
        isolatedVault = nil
        registry = nil
        store = fixture.store
        actions = fixture.actions
        Self.active = self
    }

    func validationTransport(for context: ResolvedContext) async throws -> any Transport {
        guard let registry else { throw APIError.invalidRequest }
        return try await registry.transport(for: context)
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
