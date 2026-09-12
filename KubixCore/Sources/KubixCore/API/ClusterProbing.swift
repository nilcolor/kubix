import Foundation

/// Reachability and credential acceptance for one cluster, with no namespaced authorization implied.
/// Returns the server's reported version, which the cluster pane displays; a server that answers
/// without a readable version is still reachable, so the value is optional rather than a failure.
public protocol ClusterProbing: Sendable {
    func probe(context: ResolvedContext) async throws -> String?
}
