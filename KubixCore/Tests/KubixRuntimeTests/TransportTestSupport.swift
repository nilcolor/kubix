import Foundation
import KubixCore
@testable import KubixRuntime

/// Allow the real-process tests to run alongside fake-clock tests without a busy-yield storm.
/// This waits for scheduling only; all transport deadlines are still driven by the fake clock.
func transportEventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw TestFailure.deadline }
        try await Task.sleep(for: .milliseconds(1))
    }
}

final class ManualTransportClock: TransportClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var registrations = 0
    private var waiters: [UUID: (TimeInterval, CheckedContinuation<Void, any Error>)] = [:]
    var now: TimeInterval { lock.withLock { time } }
    var deadlines: [TimeInterval] { lock.withLock { waiters.values.map(\.0).sorted() } }
    var waitCount: Int { lock.withLock { registrations } }

    func wait(until deadline: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                registrations += 1
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= time {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters[id] = (deadline, continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            let pending = self.lock.withLock { self.waiters.removeValue(forKey: id)?.1 }
            pending?.resume(throwing: CancellationError())
        }
    }

    func advance(to newTime: TimeInterval) {
        let ready = lock.withLock {
            precondition(newTime >= time)
            time = newTime
            let ready = waiters.filter { $0.value.0 <= newTime }
            for id in ready.keys { waiters.removeValue(forKey: id) }
            return ready.values.map(\.1)
        }
        for continuation in ready { continuation.resume() }
    }
}

actor TransportCredentials: CredentialProviding {
    let gate: TestGate?
    private var cache = CredentialCache(now: { Date(timeIntervalSince1970: 1_000) })
    private(set) var acquisitions = 0
    private(set) var invalidations: [CredentialCache.Generation] = []
    private(set) var acceptedInvalidations = 0
    var certificate = false
    var anonymous = false

    init(gate: TestGate? = nil, certificate: Bool = false, anonymous: Bool = false) {
        self.gate = gate
        self.certificate = certificate
        self.anonymous = anonymous
    }

    func acquire(for context: ResolvedContext, progress: @escaping AuthProgress) async throws -> AcquiredCredential {
        acquisitions += 1
        try await gate?.wait()
        let identity = try CredentialIdentity(from: context)
        if anonymous { return AcquiredCredential(identity: identity, entry: nil) }
        if case .fresh(let entry) = cache.lookup(for: identity) {
            return AcquiredCredential(identity: identity, entry: entry)
        }
        let credential = try certificate
            ? Credential(token: "synthetic-token", clientCertificateData: "certificate", clientKeyData: "key")
            : Credential(token: "synthetic-token-\(acceptedInvalidations)")
        return AcquiredCredential(identity: identity, entry: try cache.store(credential, for: identity))
    }

    func invalidate(_ identity: CredentialIdentity, failedGeneration: CredentialCache.Generation) {
        invalidations.append(failedGeneration)
        if cache.invalidate(identity, generation: failedGeneration) { acceptedInvalidations += 1 }
    }
}

final class MemoryByteStream: HTTPByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data]
    private var finished: Bool
    private var pending: TransportPromise<Data?>?
    private(set) var cancellationCount = 0
    var isWaiting: Bool { lock.withLock { pending != nil } }
    var cancelled: Bool { lock.withLock { cancellationCount > 0 } }

    init(_ chunks: [Data] = [], finished: Bool = false) { self.chunks = chunks; self.finished = finished }

    func read() async throws -> Data? {
        let promise = TransportPromise<Data?>()
        let ready: Result<Data?, any Error>? = lock.withLock {
            if cancellationCount > 0 { return .failure(CancellationError()) }
            if !chunks.isEmpty { return .success(chunks.removeFirst()) }
            if finished { return .success(nil) }
            pending = promise
            return nil
        }
        if let ready { return try ready.get() }
        return try await promise.value(cancel: cancel)
    }

    func yield(_ data: Data?) {
        let promise = lock.withLock {
            let promise = pending
            pending = nil
            if let data { if promise == nil { chunks.append(data) } } else { finished = true }
            return promise
        }
        promise?.finish(.success(data))
    }

    func cancel() {
        let promise = lock.withLock {
            cancellationCount += 1
            let promise = pending
            pending = nil
            return promise
        }
        promise?.finish(.failure(CancellationError()))
    }
}

final class TransportSocket: WebSocketConnection, @unchecked Sendable {
    enum PingMode { case success, failure, blackhole }
    let negotiatedProtocol: String?
    let incoming = MemoryByteStream()
    private let lock = NSLock()
    private let pingMode: PingMode
    private let blockedSend: Bool
    private let pong = TransportPromise<Void>()
    private let sent = TransportPromise<Void>()
    private var counts = (pings: 0, sends: 0, cancellations: 0)
    var pings: Int { lock.withLock { counts.pings } }
    var sends: Int { lock.withLock { counts.sends } }
    var cancelled: Bool { lock.withLock { counts.cancellations > 0 } }

    init(protocolName: String? = "v5.channel.k8s.io", ping: PingMode = .success, blockedSend: Bool = false) {
        negotiatedProtocol = protocolName
        pingMode = ping
        self.blockedSend = blockedSend
    }

    func send(_ data: Data) async throws {
        lock.withLock { counts.sends += 1 }
        if blockedSend { try await sent.value(cancel: cancel) }
    }

    func receive() async throws -> Data {
        guard let data = try await incoming.read() else { throw APIError.transport(.closed) }
        return data
    }

    func ping() async throws {
        lock.withLock { counts.pings += 1 }
        switch pingMode {
        case .success: return
        case .failure: throw APIError.transport(.pingFailed)
        case .blackhole: try await pong.value(cancel: {})
        }
    }

    func deliverPong() { pong.finish(.success(())) }
    func cancel() {
        lock.withLock { counts.cancellations += 1 }
        incoming.cancel()
        sent.finish(.failure(CancellationError()))
        // A missed pong is completed by task cancellation, not by a fictitious response.
    }
}

actor ScriptedTransportSession: TransportSession {
    typealias DataHandler = @Sendable (URLRequest, Int) async throws -> HTTPDataResponse
    typealias StreamHandler = @Sendable (URLRequest, Int) async throws -> HTTPStreamResponse
    typealias SocketHandler = @Sendable (URLRequest, Int) async throws -> any WebSocketConnection
    private let onData: DataHandler
    private let onStream: StreamHandler
    private let onSocket: SocketHandler
    private(set) var requests: [URLRequest] = []
    private(set) var streamRequests: [URLRequest] = []
    private(set) var socketRequests: [URLRequest] = []

    init(
        data: @escaping DataHandler = { _, _ in HTTPDataResponse(statusCode: 200, body: Data("ok".utf8)) },
        stream: @escaping StreamHandler = { _, _ in HTTPStreamResponse(statusCode: 200, body: MemoryByteStream()) },
        socket: @escaping SocketHandler = { _, _ in TransportSocket() }
    ) {
        onData = data
        onStream = stream
        onSocket = socket
    }
    func data(for request: URLRequest) async throws -> HTTPDataResponse {
        requests.append(request)
        return try await onData(request, requests.count)
    }
    func stream(for request: URLRequest) async throws -> HTTPStreamResponse {
        streamRequests.append(request)
        return try await onStream(request, streamRequests.count)
    }
    func connect(request: URLRequest) async throws -> any WebSocketConnection {
        socketRequests.append(request)
        return try await onSocket(request, socketRequests.count)
    }
}

final class RecordingSessionFactory: TransportSessionFactory, @unchecked Sendable {
    private let lock = NSLock()
    let session: ScriptedTransportSession
    private var records: [(TransportPurpose, ClusterTrustPolicy)] = []
    var policies: [(TransportPurpose, ClusterTrustPolicy)] { lock.withLock { records } }
    init(_ session: ScriptedTransportSession = ScriptedTransportSession()) { self.session = session }
    func make(purpose: TransportPurpose, trust: ClusterTrustPolicy) -> any TransportSession {
        lock.withLock { records.append((purpose, trust)) }
        return session
    }
}

func transportConfiguration(cluster: KubeconfigCluster = KubeconfigCluster(server: "https://synthetic.invalid")) -> Kubeconfig {
    Kubeconfig(currentContext: "test", clusters: [NamedCluster(name: "cluster", cluster: cluster)],
               contexts: [NamedContext(name: "test", context: KubeconfigContext(cluster: "cluster"))])
}

func testTransport(
    session: ScriptedTransportSession, credentials: any CredentialProviding = TransportCredentials(),
    clock: any TransportClock = ManualTransportClock()
) async throws -> URLSessionTransport {
    try await URLSessionTransport(
        context: transportConfiguration().resolve(), credentials: credentials,
        factory: RecordingSessionFactory(session), clock: clock, warning: { _ in }
    )
}

let podsRequest = APIRequest(resource: "pods", namespace: "team")
let execRequest = APIRequest(resource: "pods", namespace: "team", name: "pod", subresource: "exec",
                             query: [URLQueryItem(name: "command", value: "sh")])

struct InMemoryTransport: Transport {
    let response: Data
    let bytes: any HTTPByteStream
    let socket: any WebSocketConnection
    func data(for request: APIRequest) async throws -> Data { response }
    func stream(for request: APIRequest, purpose: TransportPurpose) async throws -> any HTTPByteStream { bytes }
    func webSocket(for request: APIRequest) async throws -> any WebSocketConnection { socket }
}
