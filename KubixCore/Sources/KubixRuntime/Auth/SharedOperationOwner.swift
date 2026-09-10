import Foundation

/// Lifetime ownership is separate from active/cache/retry indexes. Cancelled operations stay
/// owned until their actions finish cleanup, even when a replacement has taken their key.
final class SharedOperationOwner<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var operations: [SharedOperation<Value>] = []

    func checkOpen() throws {
        try Task.checkCancellation()
        try lock.withLock {
            if stopped { throw CancellationError() }
        }
    }

    func make(_ action: @escaping SharedOperation<Value>.Action) throws -> SharedOperation<Value> {
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            operations.removeAll { $0.isWorkerFinished }
            let operation = SharedOperation(action: action)
            operations.append(operation)
            return operation
        }
    }

    func cancelAll() {
        let pending = lock.withLock {
            stopped = true
            return operations
        }
        // Cancellation can synchronously cascade to another owner; never hold this lock.
        for operation in pending { operation.cancel() }
    }

    func shutdown() async {
        cancelAll()
        let pending = lock.withLock { operations }
        for operation in pending { await operation.waitForCompletion() }
        lock.withLock { operations.removeAll() }
    }
}
