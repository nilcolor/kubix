#if DEBUG
import AppKit
import KubixCore
import KubixRuntime

/// Fixed, in-memory dependencies for the native smoke. No real config, credentials, browser or transport.
@MainActor final class PodBrowsingFixture {
    let store = AppStore()
    let transport = PodFixtureTransport()
    let authentication = PodFixtureAuth()
    let surfaces = PodFixtureSurfaces()
    let actions: AppActions

    init() {
        actions = AppActions(
            store: store, exec: PodFixtureExec(), authentication: authentication, surfaces: surfaces,
            configurations: PodFixtureConfiguration(), pods: WatchService(transports: { [transport] _ in transport })
        )
    }
}

private struct PodFixtureConfiguration: AppConfigurationLoading {
    func load() -> AppConfiguration {
        let config = Kubeconfig(
            currentContext: "synthetic-first",
            clusters: [
                .init(name: "safe", cluster: .init(server: "https://synthetic.invalid")),
                .init(name: "blocked", cluster: .init(server: "https://synthetic.invalid", proxyURL: "http://synthetic.invalid")),
            ],
            contexts: [
                .init(name: "synthetic-first", context: .init(cluster: "safe", user: "wrapper", namespace: "team")),
                .init(name: "synthetic-second", context: .init(cluster: "safe", user: "wrapper", namespace: "other")),
                .init(name: "synthetic-proxy", context: .init(cluster: "blocked", namespace: "never")),
            ],
            users: [.init(name: "wrapper", user: .init(exec: .init(
                command: "/synthetic/configured-wrapper", apiVersion: "client.authentication.k8s.io/v1", interactiveMode: "Never"
            ))) ]
        )
        return AppConfiguration(configuration: config, settings: AuthSettings())
    }
}

actor PodFixtureTransport: Transport {
    private(set) var requests: [APIRequest] = []
    private(set) var streams: [PodFixtureStream] = []

    func data(for request: APIRequest) async throws -> Data {
        requests.append(request)
        guard request.path.count == 5, request.path.prefix(3) == ["api", "v1", "namespaces"],
              request.path.last == "pods", request.accept == APIRequest.tableAccept,
              ["team", "other", "known", "empty", "forbidden"].contains(request.path[3]) else { throw APIError.invalidRequest }
        let namespace = request.path[3]
        if namespace == "forbidden" { throw APIError.http(code: 403, resource: "pods") }
        let second = request.query.contains { $0.name == "continue" }
        if second { try await Task.sleep(for: .seconds(1)) }
        return Self.page(namespace: namespace, second: second, empty: namespace == "empty")
    }

    func stream(for request: APIRequest, purpose: TransportPurpose) throws -> any HTTPByteStream {
        guard purpose == .watch, request.path.last == "pods" else { throw APIError.invalidRequest }
        let stream = PodFixtureStream()
        streams.append(stream)
        return stream
    }

    func webSocket(for request: APIRequest) throws -> any WebSocketConnection { throw APIError.invalidRequest }

    static func page(namespace: String, second: Bool, empty: Bool) -> Data {
        let schema = second ? "null" : """
        [{"name":"Workload","type":"string"},{"name":"Count","type":"integer"},
         {"name":"Flag","type":"boolean"},{"name":"Workload","type":"string","priority":1},
         {"name":"Custom","type":"future","priority":2}]
        """
        let row = second
            ? #"{"cells":["alpha",2,true,"node1",null],"object":{"metadata":{"uid":"uid-a","name":"alpha","namespace":"\#(namespace)"}}}"#
            : #"{"cells":["zulu",10,false,"node2",{"a":1}],"object":{"metadata":{"uid":"uid-z","name":"zulu","namespace":"\#(namespace)"}}}"#
        return Data("""
        {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"list","continue":"\(second || empty ? "" : "next")"},
         "columnDefinitions":\(schema),"rows":[\(empty ? "" : row)]}
        """.utf8)
    }

    func modify() {
        let event = """
        {"type":"MODIFIED","object":{"apiVersion":"meta.k8s.io/v1","kind":"Table","rows":[
        {"cells":["aardvark",1,false,"node2",{"a":2}],"object":{"metadata":{"uid":"uid-z","name":"zulu","namespace":"team","resourceVersion":"next"}}}]} }
        """.replacingOccurrences(of: "\n", with: "")
        streams.last?.yield(Data((event + "\n").utf8))
    }
}

/// All mutable state is protected by the lock, including cancellation-before-read.
final class PodFixtureStream: HTTPByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var pending: CheckedContinuation<Data?, any Error>?
    private var stopped = false
    var cancelled: Bool { lock.withLock { stopped } }

    func read() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if stopped { continuation.resume(throwing: CancellationError()) } else if !chunks.isEmpty {
                        continuation.resume(returning: chunks.removeFirst())
                    } else { pending = continuation }
                }
            }
        } onCancel: { self.cancel() }
    }

    func yield(_ data: Data) {
        lock.withLock {
            guard !stopped else { return }
            if let pending { self.pending = nil; pending.resume(returning: data) } else { chunks.append(data) }
        }
    }

    func cancel() {
        lock.withLock {
            stopped = true
            chunks = []
            pending?.resume(throwing: CancellationError())
            pending = nil
        }
    }
}

actor PodFixtureAuth: AuthenticationControlling {
    private var continuation: AsyncStream<AuthSession>.Continuation?
    private var context: ResolvedContext?
    private(set) var retryCount = 0
    func sessions() -> AsyncStream<AuthSession> {
        AsyncStream { continuation = $0 }
    }
    func update(settings: AuthSettings) {}
    func cancel(operationID: UUID) {}
    func acquire(for context: ResolvedContext) throws -> AcquiredCredential {
        try AcquiredCredential(identity: CredentialIdentity(from: context), entry: nil)
    }
    func signIn(for context: ResolvedContext, useDeviceCode: Bool) throws -> AcquiredCredential { try acquire(for: context) }
    func retry(operationID: UUID) throws -> AcquiredCredential {
        retryCount += 1
        guard let context else { throw APIError.invalidRequest }
        return try acquire(for: context)
    }
    func presentation(for context: ResolvedContext) -> AuthPluginPresentation {
        AuthPluginPresentation(executable: "/synthetic/configured-wrapper", source: "injected", profile: "synthetic", canSignIn: true)
    }
    func showProgress(for context: ResolvedContext, failed: Bool) throws {
        self.context = context
        var session = AuthSession(credentialIdentity: try CredentialIdentity(from: context), provider: "Synthetic configured plugin")
        session.append("Synthetic approval instructions. No browser or login is performed.")
        session.transition(to: failed ? .failed : .waitingForBrowser, diagnostic: failed ? "Synthetic failure; retry after approval." : nil)
        continuation?.yield(session)
    }
    func finish() { continuation?.finish(); continuation = nil }
}

private struct PodFixtureExec: ExecSessionControlling {
    func run(
        sessionID: UUID, target: ExecTarget, ready: @escaping @MainActor @Sendable (ExecBridgeEndpoint) throws -> Void,
        update: @escaping @MainActor @Sendable (ExecSession.State) -> Void
    ) async -> ExecSessionResult {
        do {
            try await ready(ExecBridgeEndpoint(socketPath: "/synthetic/unused", nonce: BridgeNonce(bytes: Data(repeating: 1, count: 32))))
            await update(.running)
            try await Task.sleep(for: .seconds(120))
            return .exited(code: 0)
        } catch { return .cancelled }
    }
    func childTerminated(sessionID: UUID) {}
}

@MainActor final class PodFixtureSurfaces: TerminalSurfaceCreating {
    private(set) var created: [GhosttySurfaceView] = []
    func makeSurface(
        sessionID: UUID, target: ExecTarget, endpoint: ExecBridgeEndpoint,
        onChildExit: @escaping @MainActor @Sendable () -> Void
    ) throws -> any TerminalSurface {
        guard let directory = PodBrowsingValidation.directory else { throw APIError.invalidRequest }
        let view = GhosttySurfaceView(configuration: try TerminalConfiguration(
            command: "/bin/cat", environment: ["HOME": directory + "/home", "ZDOTDIR": directory + "/home", "SHELL": "/bin/sh"],
            workingDirectory: directory
        ))
        view.onClose = onChildExit
        created.append(view)
        return view
    }
}
#endif
