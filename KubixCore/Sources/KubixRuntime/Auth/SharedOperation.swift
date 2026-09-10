import Foundation
import KubixCore

/// Continuations give each caller prompt cancellation without awaiting an unstructured Task.value.
/// The operation owns its task; only global Cancel or losing the last subscriber cancels that task.
final class SharedOperation<Value: Sendable>: @unchecked Sendable {
    typealias Action = @Sendable (@escaping AuthProgress) async throws -> Value
    let id = UUID()
    private let lock = NSLock()
    // Serialize replay/live delivery/termination without holding the state lock across callbacks.
    // Recursive delivery permits a progress subscriber to synchronously cancel its operation.
    private let deliveryLock = NSRecursiveLock()
    private var action: Action?
    private var task: Task<Void, Never>?
    private var result: Result<Value, any Error>?
    private var waiters: [UUID: CheckedContinuation<Value, any Error>] = [:]
    private var subscribers: [UUID: AuthProgress] = [:]
    private var instructions = ""

    init(action: @escaping Action) { self.action = action }

    var isFinished: Bool { lock.withLock { result != nil } }
    var waiterCount: Int { lock.withLock { waiters.count } }

    func value(progress: @escaping AuthProgress = { _ in }) async throws -> Value {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                deliveryLock.lock()
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    deliveryLock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let result {
                    lock.unlock()
                    deliveryLock.unlock()
                    continuation.resume(with: result)
                    return
                }
                waiters[waiterID] = continuation
                subscribers[waiterID] = progress
                let replay = instructions
                if task == nil, let action {
                    task = Task {
                        do { self.complete(.success(try await action(self.emit))) } catch {
                            self.complete(.failure(error))
                        }
                    }
                }
                lock.unlock()
                if !replay.isEmpty { progress(replay) }
                deliveryLock.unlock()
            }
        } onCancel: {
            self.unsubscribe(waiterID)
        }
    }

    func cancel() {
        complete(.failure(CancellationError()), cancelTask: true)
    }

    private func emit(_ text: String) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        let sinks: [AuthProgress] = lock.withLock {
            guard result == nil else { return [] }
            instructions = AuthSession.boundedInstructions(instructions + text)
            return Array(subscribers.values)
        }
        for sink in sinks {
            if isFinished { break }
            sink(text)
        }
    }

    private func unsubscribe(_ id: UUID) {
        deliveryLock.lock()
        lock.lock()
        let continuation = waiters.removeValue(forKey: id)
        subscribers.removeValue(forKey: id)
        let empty = waiters.isEmpty && result == nil
        let owned = empty ? task : nil
        if empty {
            result = .failure(CancellationError())
            instructions = ""
            task = nil
            action = nil
        }
        lock.unlock()
        deliveryLock.unlock()
        continuation?.resume(throwing: CancellationError())
        owned?.cancel()
    }

    private func complete(_ result: Result<Value, any Error>, cancelTask: Bool = false) {
        deliveryLock.lock()
        lock.lock()
        guard self.result == nil else { lock.unlock(); deliveryLock.unlock(); return }
        self.result = result
        action = nil
        instructions = ""
        let pending = Array(waiters.values)
        waiters.removeAll()
        subscribers.removeAll()
        let owned = task
        task = nil
        lock.unlock()
        deliveryLock.unlock()
        // Cancellation handlers can synchronously enter another operation; hold neither lock here.
        if cancelTask { owned?.cancel() }
        for waiter in pending { waiter.resume(with: result) }
    }
}
