import Foundation

public protocol AuthDeadlineWaiting: Sendable {
    func wait(seconds: TimeInterval) async throws
}

public struct ContinuousAuthDeadline: AuthDeadlineWaiting {
    public init() {}
    public func wait(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// The whole login + reacquisition shares one budget, not a fresh ten minutes for each stage.
func withAuthDeadline<Value: Sendable>(
    seconds: TimeInterval, clock: any AuthDeadlineWaiting,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await clock.wait(seconds: seconds)
            throw ProcessFailure.timedOut
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}
