import Foundation
import KubixCore

/// A deployment's pods, found by **ownership** rather than by its selector alone.
///
/// A Deployment's `spec.selector` is not required to be unique, and in practice often is not: a
/// chart that gives `synthetic-container` and `web-dj-slow` the same `app` label leaves the first
/// one's selector matching the second one's pods. Selecting by labels then tails three workloads and
/// calls it one. Kubernetes answers this with `ownerReferences`: pods are owned by a ReplicaSet, and
/// that ReplicaSet is owned by the Deployment, so ownership is exact where labels are a guess.
///
/// The selector is still sent, because it narrows the request to roughly the right pods and keeps
/// both lists cheap on a large namespace. It is a filter for the server, not the answer.
public struct DeploymentPodService: DeploymentPodListing {
    public typealias TransportFactory = @Sendable (ResolvedContext) async throws -> any Transport

    /// Both requests are selector-scoped, so a deployment's pods are a page or two. These bounds
    /// exist so an endless or cycling cursor cannot spin forever; hitting one throws.
    static let pageLimit = 16
    static let byteLimit = 8 * 1_024 * 1_024

    private let transports: TransportFactory

    public init(transports: @escaping TransportFactory) { self.transports = transports }

    public func pods(
        context: ResolvedContext, namespace: String, owner: String, selector: LabelSelector
    ) async throws -> [DeploymentPod] {
        guard NamespaceSelection.isValid(namespace), !owner.isEmpty else { throw APIError.invalidRequest }
        try Task.checkCancellation()
        let transport = try await transports(context)
        let replicaSets = try await uids(
            transport, kind: .replicaSets, namespace: namespace, selector: selector, ownedBy: [owner]
        )
        // No ReplicaSet of this deployment means no pods of it either — a selector match would be
        // some other workload's.
        guard !replicaSets.isEmpty else { return [] }
        try Task.checkCancellation()
        return try await self.pods(transport, namespace: namespace, selector: selector, ownedBy: replicaSets)
    }

    /// The owned objects' UIDs, which is all the intermediate ReplicaSet step needs.
    private func uids(
        _ transport: any Transport, kind: OwnedKind, namespace: String,
        selector: LabelSelector, ownedBy owners: Set<String>
    ) async throws -> Set<String> {
        var found = Set<String>()
        try await page(transport, kind: kind, namespace: namespace, selector: selector) { metadata in
            guard let uid = metadata.uid, !uid.isEmpty, Self.isOwned(metadata, by: owners) else { return }
            found.insert(uid)
        }
        return found
    }

    private func pods(
        _ transport: any Transport, namespace: String, selector: LabelSelector, ownedBy owners: Set<String>
    ) async throws -> [DeploymentPod] {
        var pods: [DeploymentPod] = []
        var seen = Set<String>()
        try await page(transport, kind: .pods, namespace: namespace, selector: selector) { metadata in
            // A row without both a name and a UID cannot be addressed or bound to, a duplicate would
            // open the same stream twice, and a pod this deployment does not own is another
            // workload's however well its labels match.
            guard let name = metadata.name, let uid = metadata.uid, !name.isEmpty, !uid.isEmpty,
                  metadata.namespace == namespace, Self.isOwned(metadata, by: owners),
                  seen.insert(uid).inserted else { return }
            pods.append(DeploymentPod(name: name, uid: uid, created: metadata.creationTimestamp))
        }
        return DeploymentPod.newestFirst(pods)
    }

    /// Only the controller reference counts. A pod adopted by nothing, or referencing its owner
    /// without being controlled by it, is not this deployment's to tail.
    private static func isOwned(_ metadata: KubernetesObjectMetadata, by owners: Set<String>) -> Bool {
        guard let controller = metadata.controller else { return false }
        return owners.contains(controller.uid)
    }

    private func page(
        _ transport: any Transport, kind: OwnedKind, namespace: String, selector: LabelSelector,
        receive: (KubernetesObjectMetadata) -> Void
    ) async throws {
        var cursor = ""
        var bytes = 0
        for page in 0..<Self.pageLimit {
            try Task.checkCancellation()
            let request = Self.request(kind: kind, namespace: namespace, selector: selector, cursor: cursor)
            let data = try await transport.data(for: request)
            bytes += data.count
            guard bytes <= Self.byteLimit else { throw DeploymentPodFailure.tooManyBytes }
            guard let table = try? JSONDecoder().decode(KubernetesTable.self, from: data) else {
                throw DeploymentPodFailure.malformed
            }
            for row in table.rows {
                guard let metadata = row.object?.metadata else { continue }
                receive(metadata)
            }
            let next = table.metadata?.continuation ?? ""
            guard !next.isEmpty else { return }
            guard next != cursor else { throw DeploymentPodFailure.malformed }
            cursor = next
            if page == Self.pageLimit - 1 { throw DeploymentPodFailure.tooManyPages }
        }
        throw DeploymentPodFailure.tooManyPages
    }

    private enum OwnedKind {
        case replicaSets, pods

        var resource: String { self == .pods ? "pods" : "replicasets" }
        var apiPath: [String] { self == .pods ? ResourceKind.pods.apiPath : ResourceKind.deployments.apiPath }
    }

    private static func request(
        kind: OwnedKind, namespace: String, selector: LabelSelector, cursor: String
    ) -> APIRequest {
        var query = [
            URLQueryItem(name: "limit", value: "500"),
            URLQueryItem(name: "includeObject", value: "Metadata"),
            URLQueryItem(name: "labelSelector", value: selector.query),
        ]
        if !cursor.isEmpty { query.append(URLQueryItem(name: "continue", value: cursor)) }
        return APIRequest(
            resource: kind.resource, namespace: namespace, apiPath: kind.apiPath, query: query, table: true
        )
    }
}
