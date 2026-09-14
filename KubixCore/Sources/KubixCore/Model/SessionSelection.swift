import Foundation

/// Which open session the deck is showing. Shells and log tails share one strip, so they share one
/// selection: the kind is part of the value rather than a second field to keep consistent.
public enum SessionSelection: Equatable, Hashable, Sendable, Identifiable {
    case shell(UUID)
    case logs(UUID)

    public var id: UUID {
        switch self {
        case .shell(let id), .logs(let id): id
        }
    }

    public var isLogs: Bool {
        if case .logs = self { return true }
        return false
    }
}
