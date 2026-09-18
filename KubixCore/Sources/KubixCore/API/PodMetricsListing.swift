import Foundation

/// A pod's usage as the metrics API reports it, summed over its containers. The API names a pod but
/// carries no UID, so the sample's own window is what ties it to one particular pod: a window that
/// began before a pod existed cannot describe it, whatever the name says.
public struct PodUsage: Equatable, Sendable {
    public let name: String
    public let cpuNanocores: Decimal
    public let memoryBytes: Decimal
    /// When the sample was taken on the node, and how long a period it averages.
    public let timestamp: Date
    public let window: TimeInterval

    public init(name: String, cpuNanocores: Decimal, memoryBytes: Decimal, timestamp: Date, window: TimeInterval) {
        self.name = name
        self.cpuNanocores = cpuNanocores
        self.memoryBytes = memoryBytes
        self.timestamp = timestamp
        self.window = window
    }

    public var windowStart: Date { timestamp.addingTimeInterval(-window) }
}

/// Current usage for every pod in one namespace. The metrics API has no watch, so this is polled.
public protocol PodMetricsListing: Sendable {
    func podMetrics(context: ResolvedContext, namespace: String) async throws -> [PodUsage]
}

/// Whether a cluster serves `metrics.k8s.io`. `unknown` and `unavailable` are distinct for the same
/// reason namespace discovery keeps them apart: a cluster without metrics-server must not be asked
/// again on every poll, and one that has not answered yet must not lose its columns.
public enum MetricsAvailability: Equatable, Sendable {
    case unknown
    case available
    case unavailable
}

public enum PodMetricsFailure: String, Error, Equatable, Sendable {
    case malformed
    case tooManyBytes
}
