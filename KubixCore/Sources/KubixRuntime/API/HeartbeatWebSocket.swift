import Foundation
import KubixCore

/// Owns only transport liveness, not exec channels or replay. The heartbeat has an independent
/// task and never takes a send/receive lock. A blocked native ping is still bounded by its timer.
public final class HeartbeatWebSocket: WebSocketConnection, Sendable {
    public var negotiatedProtocol: String? { state.connection.negotiatedProtocol }
    private let state: HeartbeatState

    public init(connection: any WebSocketConnection, clock: any TransportClock) {
        state = HeartbeatState(connection: connection, clock: clock)
        state.start()
    }

    public func send(_ data: Data) async throws {
        try await perform { try await self.state.connection.send(data) }
    }

    public func receive() async throws -> Data {
        try await perform { try await self.state.connection.receive() }
    }

    public func ping() async throws {
        try await perform { try await self.state.ping() }
    }

    private func perform<Value: Sendable>(_ action: @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if let failure = state.failure { throw failure }
        return try await withTaskCancellationHandler {
            do {
                let value = try await action()
                if let failure = state.failure { throw failure }
                return value
            } catch {
                state.stop(state.failure ?? transportError(error))
                throw state.failure ?? error
            }
        } onCancel: { self.cancel() }
    }

    public func cancel() { state.stop(CancellationError()) }
    deinit { state.stop(CancellationError()) }
}

private final class HeartbeatState: @unchecked Sendable {
    let connection: any WebSocketConnection
    private let clock: any TransportClock
    private let lock = NSLock()
    private var error: (any Error)?
    private var task: Task<Void, Never>?
    var failure: (any Error)? { lock.withLock { error } }

    init(connection: any WebSocketConnection, clock: any TransportClock) {
        self.connection = connection
        self.clock = clock
    }

    func start() {
        let firstPing = clock.now + TransportPolicy.pingInterval
        let worker = Task {
            do {
                var next = firstPing
                while true {
                    try await clock.wait(until: next)
                    try Task.checkCancellation()
                    try await ping()
                    next = clock.now + TransportPolicy.pingInterval
                }
            } catch {
                if failure == nil {
                    let failure = error as? APIError ?? .transport(.pingFailed)
                    stop(failure)
                }
            }
        }
        let alreadyStopped = lock.withLock {
            if error != nil { return true }
            task = worker
            return false
        }
        if alreadyStopped { worker.cancel() }
    }

    func ping() async throws {
        try await withTransportDeadline(
            until: clock.now + TransportPolicy.pongTimeout, clock: clock, failure: .pongTimedOut,
            cancel: { self.stop(APIError.transport(.pongTimedOut)) },
            operation: {
                do { try await self.connection.ping() } catch is CancellationError { throw CancellationError() } catch {
                    throw APIError.transport(.pingFailed)
                }
            }
        )
    }

    func stop(_ error: any Error) {
        let worker = lock.withLock {
            guard self.error == nil else { return Optional<Task<Void, Never>>.none }
            self.error = error
            let worker = task
            task = nil
            return worker
        }
        worker?.cancel()
        connection.cancel()
    }
}
