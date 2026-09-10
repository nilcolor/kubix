import Foundation
import KubixCore
@testable import KubixRuntime

actor ExecTestQueue<Value: Sendable> {
    private var values: [Value] = []
    private var pending: (id: UUID, continuation: CheckedContinuation<Value, any Error>)?
    private var failure: (any Error)?
    var waiting: Bool { pending != nil }

    func next() async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if !values.isEmpty { return values.removeFirst() }
            if let failure { throw failure }
            return try await withCheckedThrowingContinuation { pending = (id, $0) }
        } onCancel: { Task { await self.cancel(id) } }
    }

    func yield(_ value: Value) {
        if let pending {
            self.pending = nil
            pending.continuation.resume(returning: value)
        } else { values.append(value) }
    }

    func finish(_ error: any Error) {
        failure = error
        let old = pending
        pending = nil
        old?.continuation.resume(throwing: error)
    }

    private func cancel(_ id: UUID) {
        guard pending?.id == id else { return }
        let old = pending
        pending = nil
        old?.continuation.resume(throwing: CancellationError())
    }
}

final class ExecTestSocket: WebSocketConnection, @unchecked Sendable {
    let negotiatedProtocol: String?
    let incoming = ExecTestQueue<Data>()
    let sendGate: TestGate?
    let blockAfter: Int
    let pingGate: TestGate?
    private let lock = NSLock()
    private var outgoing: [Data] = []
    private var cancelled = false
    var sent: [Data] { lock.withLock { outgoing } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    init(protocolName: String? = "v5.channel.k8s.io", sendGate: TestGate? = nil, blockAfter: Int = 0, pingGate: TestGate? = nil) {
        negotiatedProtocol = protocolName
        self.sendGate = sendGate
        self.blockAfter = blockAfter
        self.pingGate = pingGate
    }

    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        lock.withLock { outgoing.append(data) }
        if sent.count > blockAfter { try await sendGate?.wait() }
        if isCancelled { throw APIError.transport(.closed) }
    }

    func receive() async throws -> Data { try await incoming.next() }
    func ping() async throws { try await pingGate?.wait() }
    func cancel() {
        lock.withLock { cancelled = true }
        Task { await incoming.finish(CancellationError()) }
    }
}

actor ExecTestBridge: PTYBridgeSession {
    nonisolated let endpoint: ExecBridgeEndpoint
    nonisolated let incoming = ExecTestQueue<BridgeFrame>()
    let initialGate: TestGate?
    let outputGate: TestGate?
    let terminalGate: TestGate?
    var initialFailure: (any Error)?
    private(set) var initialCalls = 0
    private(set) var sent: [BridgeFrame] = []
    private(set) var sending = 0
    private(set) var closed = false
    private(set) var closes = 0
    private(set) var maximumWriters = 0

    init(
        initialGate: TestGate? = nil, outputGate: TestGate? = nil,
        initialFailure: (any Error)? = nil, terminalGate: TestGate? = nil
    ) throws {
        endpoint = try ExecBridgeEndpoint(socketPath: "/synthetic/session.sock", nonce: BridgeNonce(bytes: Data(repeating: 7, count: 32)))
        self.initialGate = initialGate
        self.outputGate = outputGate
        self.initialFailure = initialFailure
        self.terminalGate = terminalGate
    }

    func initialSize() async throws -> BridgeSize {
        initialCalls += 1
        try await initialGate?.wait()
        if let initialFailure { throw initialFailure }
        return BridgeSize(columns: 80, rows: 24)
    }

    func receive() async throws -> BridgeFrame { try await incoming.next() }
    func send(_ frame: BridgeFrame) async throws {
        guard !closed else { throw BridgeIOError.unavailable }
        sending += 1
        maximumWriters = max(maximumWriters, sending)
        defer { sending -= 1 }
        if case .data = frame { try await outputGate?.wait() } else { try await terminalGate?.wait() }
        sent.append(frame)
    }
    func close() async {
        guard !closed else { return }
        closed = true
        closes += 1
        await incoming.finish(CancellationError())
    }
}

actor ExecTestBridges: PTYBridgeServing {
    let bridge: ExecTestBridge
    private(set) var prepared: [UUID] = []
    init(_ bridge: ExecTestBridge) { self.bridge = bridge }
    func prepare(sessionID: UUID) -> any PTYBridgeSession { prepared.append(sessionID); return bridge }
}

actor ExecTestTransport: Transport {
    let socket: ExecTestSocket
    let failure: APIError?
    let upgradeGate: TestGate?
    private(set) var requests: [APIRequest] = []

    init(_ socket: ExecTestSocket, failure: APIError? = nil, upgradeGate: TestGate? = nil) {
        self.socket = socket
        self.failure = failure
        self.upgradeGate = upgradeGate
    }
    func data(for request: APIRequest) throws -> Data { throw TestFailure.missingFixture }
    func stream(for request: APIRequest, purpose: TransportPurpose) throws -> any HTTPByteStream { throw TestFailure.missingFixture }
    func webSocket(for request: APIRequest) async throws -> any WebSocketConnection {
        requests.append(request)
        try await upgradeGate?.wait()
        if let failure { throw failure }
        return socket
    }
}

@MainActor final class ExecStateCapture {
    var endpoints: [ExecBridgeEndpoint] = []
    var states: [ExecSession.State] = []
}

func execTarget() throws -> ExecTarget {
    try ExecTarget(context: runtimeContext(user: nil), namespace: "namespace", pod: "pod", container: "regular")
}

func execStatus(_ text: String = #"{"status":"Success"}"#) -> Data { Data([3]) + Data(text.utf8) }

@MainActor func execRun(
    service: ExecService, id: UUID = UUID(), capture: ExecStateCapture
) throws -> Task<ExecSessionResult, Never> {
    let target = try execTarget()
    return Task {
        await service.run(
            sessionID: id, target: target,
            ready: { capture.endpoints.append($0) }, update: { capture.states.append($0) }
        )
    }
}
