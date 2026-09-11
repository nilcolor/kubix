import Foundation

/// Reachability and credential acceptance for one cluster, with no namespaced authorization implied.
/// Deliberately returns nothing: the server's own version is not displayed anywhere, and keeping it
/// would mean retaining part of a response body for no consumer.
public protocol ClusterProbing: Sendable {
    func probe(context: ResolvedContext) async throws
}
