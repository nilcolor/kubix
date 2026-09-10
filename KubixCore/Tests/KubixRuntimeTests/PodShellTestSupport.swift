import Foundation
@testable import KubixCore
import KubixRuntime
import Testing

@MainActor final class PodShellTestOwner {
    let store: AppStore
    let actions: AppActions
    let auth: PodShellAuth
    let exec: PodShellExec
    let surfaces = PodShellSurfaces()
    let configuration: PodShellConfiguration

    init(
        transport: any Transport, auth: PodShellAuth = PodShellAuth(), exec: PodShellExec = PodShellExec(),
        watch: (any PodWatching)? = nil
    ) throws {
        self.auth = auth
        self.exec = exec
        let contexts = try ["first", "second"].map { name in
            try Kubeconfig(
                currentContext: name, clusters: [.init(name: name, cluster: .init(server: "https://\(name).synthetic.invalid"))],
                contexts: [.init(name: name, context: .init(cluster: name, namespace: "team"))]
            ).resolve()
        }
        store = AppStore(contexts: contexts)
        configuration = PodShellConfiguration(contexts: contexts)
        actions = AppActions(
            store: store, exec: exec, authentication: auth, surfaces: surfaces, configurations: configuration,
            pods: watch, podDetails: PodDetailsService { _ in transport }
        )
        try install()
    }

    func install(ids: [Int] = [0, 1], version: String = "initial") throws {
        let table = try JSONDecoder().decode(KubernetesTable.self, from: podPage(ids: ids, version: version))
        actions.applyPodUpdate(.init(rows: try table.rows.map { try PodRow(row: $0) }, columns: table.columnDefinitions, connection: .live))
    }

    func changeRow() throws {
        let bytes = String(decoding: try podPage(ids: [0, 1]), as: UTF8.self)
            .replacingOccurrences(of: "row-0", with: "changed-revision")
        let table = try JSONDecoder().decode(KubernetesTable.self, from: Data(bytes.utf8))
        actions.applyPodUpdate(.init(rows: try table.rows.map { try PodRow(row: $0) }, columns: table.columnDefinitions, connection: .live))
    }
}

actor PodShellConfiguration: AppConfigurationLoading {
    private var contexts: [ResolvedContext]
    private var gate: UncooperativeWatchGate?
    init(contexts: [ResolvedContext]) { self.contexts = contexts }
    func replace(_ contexts: [ResolvedContext]) { self.contexts = contexts }
    func block(on gate: UncooperativeWatchGate) { self.gate = gate }
    func load() async -> AppConfiguration {
        await gate?.wait()
        var config = AppConfiguration(configuration: nil, settings: nil)
        config.contexts = contexts
        return config
    }
}

actor PodShellAuth: AuthenticationControlling {
    let gate: UncooperativeWatchGate?
    private(set) var acquisitions: [ResolvedContext] = []
    var fails = false
    init(gate: UncooperativeWatchGate? = nil) { self.gate = gate }
    func setFailure(_ value: Bool) { fails = value }
    func acquire(for context: ResolvedContext) async throws -> AcquiredCredential {
        acquisitions.append(context)
        if acquisitions.count == 1 { await gate?.wait() }
        if fails { throw AuthenticationError.settingsUnavailable }
        return try AcquiredCredential(identity: CredentialIdentity(from: context), entry: nil)
    }
    func sessions() -> AsyncStream<AuthSession> { AsyncStream { $0.finish() } }
    func update(settings: AuthSettings) {}
    func cancel(operationID: UUID) async { await gate?.open() }
    func signIn(for context: ResolvedContext, useDeviceCode: Bool) async throws -> AcquiredCredential { try await acquire(for: context) }
    func retry(operationID: UUID) throws -> AcquiredCredential { throw APIError.invalidRequest }
}

actor PodShellExec: ExecSessionControlling {
    private(set) var targets: [ExecTarget] = []
    private(set) var cancelled = 0
    let gate: UncooperativeWatchGate?
    init(gate: UncooperativeWatchGate? = nil) { self.gate = gate }
    func run(
        sessionID: UUID, target: ExecTarget, ready: @escaping @MainActor @Sendable (ExecBridgeEndpoint) throws -> Void,
        update: @escaping @MainActor @Sendable (ExecSession.State) -> Void
    ) async -> ExecSessionResult {
        targets.append(target)
        await gate?.wait()
        do {
            try await ready(ExecBridgeEndpoint(socketPath: "/synthetic/unused", nonce: BridgeNonce(bytes: Data(repeating: 1, count: 32))))
            await update(.running)
            try await Task.sleep(for: .seconds(120))
            return .exited(code: 0)
        } catch { cancelled += 1; return .cancelled }
    }
    func childTerminated(sessionID: UUID) {}
}

@MainActor final class PodShellSurface: TerminalSurface {
    var frees = 0
    func teardown() { frees += 1 }
}

@MainActor final class PodShellSurfaces: TerminalSurfaceCreating {
    var created: [UUID: PodShellSurface] = [:]
    func makeSurface(
        sessionID: UUID, target: ExecTarget, endpoint: ExecBridgeEndpoint,
        onChildExit: @escaping @MainActor @Sendable () -> Void
    ) -> any TerminalSurface {
        let surface = PodShellSurface()
        created[sessionID] = surface
        return surface
    }
}
