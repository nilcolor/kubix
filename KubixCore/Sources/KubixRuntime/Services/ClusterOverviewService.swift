import Foundation
import KubixCore

/// Cluster-wide counts for the dashboard, through the same authenticated transport as everything
/// else. Every list is followed to its last page and reduced to numbers page by page, so memory stays
/// at one page however large the cluster is.
public struct ClusterOverviewService: ClusterOverviewListing {
    public typealias TransportFactory = @Sendable (ResolvedContext) async throws -> any Transport

    /// Per section, per poll. 64 pages of 500 is 32,000 objects; the byte bound keeps a cluster with
    /// enormous objects from costing tens of megabytes every thirty seconds.
    static let pageLimit = 64
    static let byteLimit = 64 * 1_024 * 1_024
    static let pageSize = "500"

    /// Pods are counted per phase with a server-side field selector, so only a name-sized Table row
    /// crosses the wire per pod, instead of a full pod object whose status holds the phase.
    static let podPhases = ["Pending", "Running", "Succeeded", "Failed", "Unknown"]

    private let transports: TransportFactory

    public init(transports: @escaping TransportFactory) { self.transports = transports }

    public func nodes(context: ResolvedContext) async throws -> NodeCounts {
        var counts = NodeCounts()
        try await objects(NodeObject.self, resource: "nodes", apiPath: ["api", "v1"], context: context) {
            counts.add($0)
        }
        return counts
    }

    /// Events are kept only as long as the apiserver's event TTL, an hour by default, so this is the
    /// warnings the cluster still remembers.
    public func warningEvents(context: ResolvedContext) async throws -> Int {
        try await rows(resource: "events", apiPath: ["api", "v1"], fieldSelector: "type=Warning", context: context)
    }

    public func workloads(_ kind: WorkloadKind, context: ResolvedContext) async throws -> WorkloadCounts {
        if kind == .pods { return try await pods(context: context) }
        var counts = WorkloadCounts.empty(kind)
        try await objects(WorkloadObject.self, resource: kind.resource, apiPath: kind.apiPath, context: context) {
            counts.add($0, as: kind)
        }
        return counts
    }

    private func pods(context: ResolvedContext) async throws -> WorkloadCounts {
        var phases: [String: Int] = [:]
        for phase in Self.podPhases {
            phases[phase] = try await rows(
                resource: "pods", apiPath: ["api", "v1"], fieldSelector: "status.phase=\(phase)", context: context
            )
        }
        return WorkloadCounts(
            total: phases.values.reduce(0, +), running: phases["Running", default: 0],
            succeeded: phases["Succeeded", default: 0], pending: phases["Pending", default: 0],
            failed: phases["Failed", default: 0]
        )
    }

    /// Counts the rows of a Table that carries no objects at all.
    private func rows(resource: String, apiPath: [String], fieldSelector: String, context: ResolvedContext) async throws -> Int {
        var count = 0
        try await pages(context: context) { cursor in
            var query = [
                URLQueryItem(name: "limit", value: Self.pageSize),
                URLQueryItem(name: "includeObject", value: "None"),
                URLQueryItem(name: "fieldSelector", value: fieldSelector),
            ]
            if !cursor.isEmpty { query.append(URLQueryItem(name: "continue", value: cursor)) }
            return APIRequest(resource: resource, apiPath: apiPath, query: query, table: true)
        } decode: { data in
            guard let table = try? JSONDecoder().decode(KubernetesTable.self, from: data) else {
                throw ClusterOverviewFailure.malformed
            }
            count += table.rows.count
            return table.metadata?.continuation ?? ""
        }
        return count
    }

    private func objects<Item: Decodable>(
        _ type: Item.Type, resource: String, apiPath: [String], context: ResolvedContext, each: (Item) -> Void
    ) async throws {
        try await pages(context: context) { cursor in
            var query = [URLQueryItem(name: "limit", value: Self.pageSize)]
            if !cursor.isEmpty { query.append(URLQueryItem(name: "continue", value: cursor)) }
            return APIRequest(resource: resource, apiPath: apiPath, query: query)
        } decode: { data in
            guard let list = try? JSONDecoder().decode(ObjectList<Item>.self, from: data) else {
                throw ClusterOverviewFailure.malformed
            }
            list.items.forEach(each)
            return list.metadata?.continuation ?? ""
        }
    }

    private func pages(
        context: ResolvedContext, request: (String) -> APIRequest, decode: (Data) throws -> String
    ) async throws {
        try Task.checkCancellation()
        let transport = try await transports(context)
        var cursor = ""
        var bytes = 0
        for _ in 0..<Self.pageLimit {
            try Task.checkCancellation()
            let data = try await transport.data(for: request(cursor))
            bytes += data.count
            guard bytes <= Self.byteLimit else { throw ClusterOverviewFailure.tooManyBytes }
            let next = try decode(data)
            guard !next.isEmpty else { return }
            guard next != cursor else { throw ClusterOverviewFailure.malformed }
            cursor = next
        }
        throw ClusterOverviewFailure.tooManyPages
    }

    private struct ObjectList<Item: Decodable>: Decodable {
        let metadata: KubernetesTable.ListMetadata?
        let items: [Item]

        enum CodingKeys: String, CodingKey { case metadata, items }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            metadata = try values.decodeIfPresent(KubernetesTable.ListMetadata.self, forKey: .metadata)
            // The server writes `null` for an empty list.
            items = try values.decodeIfPresent([Item].self, forKey: .items) ?? []
        }
    }
}
