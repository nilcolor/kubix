import Foundation

public enum TransportPurpose: CaseIterable, Sendable {
    case request, watch, logs, webSocket
}

public struct TransportPolicy: Equatable, Sendable {
    public let idleTimeout: TimeInterval
    public let totalTimeout: TimeInterval
    public let serverLease: Int?

    public static let upgradeTimeout: TimeInterval = 30
    public static let pingInterval: TimeInterval = 15
    public static let pongTimeout: TimeInterval = 15

    public static func policy(for purpose: TransportPurpose) -> Self {
        switch purpose {
        case .request: Self(idleTimeout: 30, totalTimeout: 60, serverLease: nil)
        case .watch: Self(idleTimeout: 330, totalTimeout: 330, serverLease: 300)
        case .logs, .webSocket:
            // The exec upgrade has its own deadline. A session resource timeout of 30/60s
            // would also kill an already-upgraded, healthy WebSocket.
            Self(idleTimeout: 24 * 60 * 60, totalTimeout: 7 * 24 * 60 * 60, serverLease: nil)
        }
    }
}

/// Monotonic seconds, never wall-clock dates. wait must respond promptly to task cancellation.
public protocol TransportClock: Sendable {
    var now: TimeInterval { get }
    func wait(until deadline: TimeInterval) async throws
}
