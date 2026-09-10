import Foundation
import KubixCore

/// The native receive pump owns at most 1 MiB / 256 messages while the consumer is stalled.
/// No unbounded AsyncStream and no silent frame dropping. A single consumer preserves ordering.
final class WebSocketReceiveBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [Data] = []
    private var byteCount = 0
    private var waiter: TransportPromise<Data>?
    private var error: (any Error)?

    func append(_ data: Data) throws {
        let pending: TransportPromise<Data>? = try lock.withLock {
            if let error { throw error }
            guard data.count <= 1_048_576 else { throw APIError.transport(.receiveBufferOverflow) }
            if let waiter {
                self.waiter = nil
                return waiter
            }
            guard messages.count < 256, byteCount + data.count <= 1_048_576 else {
                throw APIError.transport(.receiveBufferOverflow)
            }
            messages.append(data)
            byteCount += data.count
            return nil
        }
        pending?.finish(.success(data))
    }

    func read(cancel: @escaping @Sendable () -> Void) async throws -> Data {
        try Task.checkCancellation()
        let promise = TransportPromise<Data>()
        let ready: Result<Data, any Error>? = lock.withLock {
            if !messages.isEmpty {
                let data = messages.removeFirst()
                byteCount -= data.count
                return .success(data)
            }
            if let error { return .failure(error) }
            if waiter != nil { return .failure(APIError.transport(.receiveInProgress)) }
            waiter = promise
            return nil
        }
        if let ready { return try ready.get() }
        return try await promise.value(cancel: cancel)
    }

    func finish(_ error: any Error, discardBuffered: Bool = false) {
        let pending = lock.withLock {
            guard self.error == nil else { return Optional<TransportPromise<Data>>.none }
            self.error = error
            if discardBuffered {
                messages.removeAll()
                byteCount = 0
            }
            let pending = waiter
            waiter = nil
            return pending
        }
        pending?.finish(.failure(error))
    }
}

/// Explicit close must unblock pending send/pong callbacks even if Foundation never calls them.
final class WebSocketPendingCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [UUID: @Sendable (any Error) -> Void] = [:]
    private var error: (any Error)?

    func add(_ failure: @escaping @Sendable (any Error) -> Void) throws -> UUID {
        try lock.withLock {
            if let error { throw error }
            let id = UUID()
            calls[id] = failure
            return id
        }
    }

    func remove(_ id: UUID) { _ = lock.withLock { calls.removeValue(forKey: id) } }

    func finish(_ error: any Error) {
        let pending = lock.withLock {
            guard self.error == nil else { return [@Sendable (any Error) -> Void]() }
            self.error = error
            let pending = Array(calls.values)
            calls.removeAll()
            return pending
        }
        for failure in pending { failure(error) }
    }
}
