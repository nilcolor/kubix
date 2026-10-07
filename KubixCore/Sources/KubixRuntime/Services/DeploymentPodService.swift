import Foundation
import KubixCore

public struct DeploymentPodService: DeploymentPodListing {
    public typealias TransportFactory = @Sendable (ResolvedContext) async throws -> any Transport

    /// The request is scoped by the selector, so a deployment's pods are a page or two. These bounds
    /// exist so an endless or cycling cursor cannot spin forever; hitting one throws.
    static let pageLimit = 16
    static let byteLimit = 8 * 1_024 * 1_024

    private let transports: TransportFactory

    public init(transports: @escaping TransportFactory) { self.transports = transports }

    public func pods(
        context: ResolvedContext, namespace: String, selector: LabelSelector
    ) async throws -> [DeploymentPod] {
        guard NamespaceSelection.isValid(namespace) else { throw APIError.invalidRequest }
        try Task.checkCancellation()
        let transport = try await transports(context)
        var pods: [DeploymentPod] = []
        var seen = Set<String>()
        var cursor = ""
        var bytes = 0
        for page in 0..<Self.pageLimit {
            try Task.checkCancellation()
            let data = try await transport.data(for: Self.request(namespace: namespace, selector: selector, cursor: cursor))
            bytes += data.count
            guard bytes <= Self.byteLimit else { throw DeploymentPodFailure.tooManyBytes }
            guard let table = try? JSONDecoder().decode(KubernetesTable.self, from: data) else {
                throw DeploymentPodFailure.malformed
            }
            for row in table.rows {
                // A row without both a name and a UID cannot be addressed or bound to, and a
                // duplicate would open the same stream twice.
                guard let metadata = row.object?.metadata, let name = metadata.name, let uid = metadata.uid,
                      !name.isEmpty, !uid.isEmpty, metadata.namespace == namespace,
                      seen.insert(uid).inserted else { continue }
                pods.append(DeploymentPod(name: name, uid: uid, created: metadata.creationTimestamp))
            }
            let next = table.metadata?.continuation ?? ""
            guard !next.isEmpty else { return Self.newestFirst(pods) }
            guard next != cursor else { throw DeploymentPodFailure.malformed }
            cursor = next
            if page == Self.pageLimit - 1 { throw DeploymentPodFailure.tooManyPages }
        }
        throw DeploymentPodFailure.tooManyPages
    }

    /// Newest first, because during a rollout the new replicas are the ones worth reading, and that
    /// is also the order the source ceiling keeps. Pods the server dated identically, or not at all,
    /// fall back to their names so the order is stable between calls.
    static func newestFirst(_ pods: [DeploymentPod]) -> [DeploymentPod] {
        pods.sorted { lhs, rhs in
            let left = lhs.created?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude
            let right = rhs.created?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude
            if left != right { return left > right }
            return lhs.name < rhs.name
        }
    }

    private static func request(namespace: String, selector: LabelSelector, cursor: String) -> APIRequest {
        var query = [
            URLQueryItem(name: "limit", value: "500"),
            URLQueryItem(name: "includeObject", value: "Metadata"),
            URLQueryItem(name: "labelSelector", value: selector.query),
        ]
        if !cursor.isEmpty { query.append(URLQueryItem(name: "continue", value: cursor)) }
        return APIRequest(
            resource: ResourceKind.pods.resource, namespace: namespace,
            apiPath: ResourceKind.pods.apiPath, query: query, table: true
        )
    }
}
