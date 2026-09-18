import Foundation
import KubixCore

/// `metrics.k8s.io` pod usage for one namespace, through the same authenticated transport as the
/// watch. The API has no watch and no pagination: one list per poll.
public struct PodMetricsService: PodMetricsListing {
    public typealias TransportFactory = @Sendable (ResolvedContext) async throws -> any Transport

    /// A few hundred pods is roughly 100 KiB. The bound exists so a misbehaving aggregated API cannot
    /// hand the app an unbounded body on every poll, not as a routine path.
    static let byteLimit = 8 * 1_024 * 1_024

    private let transports: TransportFactory

    public init(transports: @escaping TransportFactory) { self.transports = transports }

    public func podMetrics(context: ResolvedContext, namespace: String) async throws -> [PodUsage] {
        try Task.checkCancellation()
        let transport = try await transports(context)
        try Task.checkCancellation()
        let data = try await transport.data(for: APIRequest(
            resource: "pods", namespace: namespace, apiPath: ["apis", "metrics.k8s.io", "v1beta1"]
        ))
        guard data.count <= Self.byteLimit else { throw PodMetricsFailure.tooManyBytes }
        guard let list = try? JSONDecoder().decode(MetricsList.self, from: data), list.kind == "PodMetricsList" else {
            throw PodMetricsFailure.malformed
        }
        // A pod whose sample cannot be read is left without numbers; it does not void the others.
        return list.items.compactMap(\.usage)
    }

    private struct MetricsList: Decodable {
        let kind: String
        let items: [Item]
    }

    private struct Metadata: Decodable { let name: String }
    private struct Usage: Decodable {
        let cpu: String
        let memory: String
    }
    private struct Container: Decodable { let usage: Usage }

    private struct Item: Decodable {
        let metadata: Metadata
        let timestamp: String
        let window: String
        let containers: [Container]

        var usage: PodUsage? {
            guard !metadata.name.isEmpty, let taken = RFC3339.date(from: timestamp),
                  let window = GoDuration.parse(self.window) else { return nil }
            var cpu: Decimal = 0
            var memory: Decimal = 0
            for container in containers {
                guard let cores = ResourceQuantity.parse(container.usage.cpu),
                      let bytes = ResourceQuantity.parse(container.usage.memory) else { return nil }
                cpu += cores * 1_000_000_000
                memory += bytes
            }
            return PodUsage(name: metadata.name, cpuNanocores: cpu, memoryBytes: memory, timestamp: taken, window: window)
        }
    }
}
