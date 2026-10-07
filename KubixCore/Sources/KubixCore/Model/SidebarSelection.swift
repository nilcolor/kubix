import Foundation

/// What the sidebar has selected. Grouping rows such as `Workload` are deliberately absent: they
/// organize the tree without selecting anything, so they cannot reach a watch.
public enum SidebarSelection: Hashable, Sendable {
    case cluster(String)
    case list(String, ResourceKind)

    public var clusterName: String {
        switch self {
        case .cluster(let name), .list(let name, _): name
        }
    }

    /// The kind this selection lists, or nil for a cluster's own pane.
    public var kind: ResourceKind? {
        switch self {
        case .cluster: nil
        case .list(_, let kind): kind
        }
    }

    /// Keeps a selection pointing at something that still exists and can still show what it claims: a
    /// list for a cluster that is no longer connected falls back to that cluster's own pane.
    public static func reconcile(
        _ selection: SidebarSelection?, clusters: [ClusterStatus], preferred: String?
    ) -> SidebarSelection? {
        guard !clusters.isEmpty else { return nil }
        guard let selection, let cluster = clusters.first(where: { $0.id == selection.clusterName }) else {
            let fallback = preferred.flatMap { name in clusters.first { $0.id == name } } ?? clusters[0]
            return .cluster(fallback.id)
        }
        if case .list = selection, cluster.state != .connected { return .cluster(cluster.id) }
        return selection
    }
}
