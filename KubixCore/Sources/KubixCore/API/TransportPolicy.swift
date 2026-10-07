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

    /// How many log streams may follow at once. A deployment's logs are one stream per pod, so this
    /// is also the ceiling on how many of a deployment's pods a tab tails.
    ///
    /// It is a resource bound, not a protocol one: Kubernetes has no aggregated log endpoint, so the
    /// number of streams is the client's choice. `kubectl` caps concurrency at 5 and refuses above
    /// it; this tails the whole set up to here and says so when it does not fit.
    ///
    /// **Why the session configures `httpMaximumConnectionsPerHost` from it.** URLSession defaults to
    /// 6 connections per host, which over HTTP/1.1 would queue the seventh stream behind the first
    /// six — a tab that looked like it was following twelve pods while six of them sat idle. The
    /// apiserver speaks HTTP/2, where these are multiplexed streams rather than connections and the
    /// limit should not apply; rather than depend on being served h2, the `.logs` session raises the
    /// limit to this number so the behaviour is the same either way.
    public static let maximumConcurrentLogStreams = 50

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
