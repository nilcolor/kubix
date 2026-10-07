#if DEBUG
import AppKit
import KubixCore
import KubixRuntime

/// The native smoke's non-transport doubles: the log/watch stream, authentication, exec,
/// terminal surfaces and the metrics endpoint's own transport.
final class PodFixtureStream: HTTPByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var pending: CheckedContinuation<Data?, any Error>?
    private var stopped = false
    private var failure: APIError?
    var cancelled: Bool { lock.withLock { stopped } }

    func read() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if stopped { continuation.resume(throwing: CancellationError()) } else if let failure {
                        continuation.resume(throwing: failure)
                    } else if !chunks.isEmpty {
                        continuation.resume(returning: chunks.removeFirst())
                    } else { pending = continuation }
                }
            }
        } onCancel: { self.cancel() }
    }

    func fail() {
        lock.withLock {
            failure = .transport(.connection)
            pending?.resume(throwing: APIError.transport(.connection))
            pending = nil
        }
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

struct PodFixtureExec: ExecSessionControlling {
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
/// The metrics API, off until the driver's usage stage turns it on: until then it answers like a
/// metrics-server that is restarting, which keeps the cluster's availability undecided and the usage
/// columns out of every earlier stage.
actor PodFixtureMetrics: Transport {
    private var usage: [String: (cpu: String, memory: String)]?
    private(set) var requests = 0

    func serve(_ usage: [String: (cpu: String, memory: String)]) { self.usage = usage }

    func data(for request: APIRequest) async throws -> Data {
        requests += 1
        guard let usage, request.path == ["apis", "metrics.k8s.io", "v1beta1", "namespaces", "timed", "pods"] else {
            throw APIError.http(code: 503, resource: "pods")
        }
        let now = PodFixtureTransport.timestamp(Date())
        let items = usage.sorted { $0.key < $1.key }.map { name, value in
            #"{"metadata":{"name":"\#(name)","namespace":"timed"},"timestamp":"\#(now)","window":"15s","containers":[{"name":"app","usage":{"cpu":"\#(value.cpu)","memory":"\#(value.memory)"}}]}"#
        }.joined(separator: ",")
        return Data(#"{"kind":"PodMetricsList","apiVersion":"metrics.k8s.io/v1beta1","items":[\#(items)]}"#.utf8)
    }

    func stream(for request: APIRequest, purpose: TransportPurpose) throws -> any HTTPByteStream { throw APIError.invalidRequest }
    func webSocket(for request: APIRequest) throws -> any WebSocketConnection { throw APIError.invalidRequest }
}
#endif
