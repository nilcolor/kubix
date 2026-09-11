import Foundation

/// What the sidebar has selected. Grouping rows such as `Workload` are deliberately absent: they
/// organize the tree without selecting anything, so they cannot reach a watch.
public enum SidebarSelection: Hashable, Sendable {
    case cluster(String)
    case pods(String)

    public var clusterName: String {
        switch self {
        case .cluster(let name), .pods(let name): name
        }
    }

    /// Keeps a selection pointing at something that still exists and can still show what it claims:
    /// pods for a cluster that is no longer connected falls back to that cluster's own pane.
    public static func reconcile(
        _ selection: SidebarSelection?, clusters: [ClusterStatus], preferred: String?
    ) -> SidebarSelection? {
        guard !clusters.isEmpty else { return nil }
        guard let selection, let cluster = clusters.first(where: { $0.id == selection.clusterName }) else {
            let fallback = preferred.flatMap { name in clusters.first { $0.id == name } } ?? clusters[0]
            return .cluster(fallback.id)
        }
        if case .pods = selection, cluster.state != .connected { return .cluster(cluster.id) }
        return selection
    }
}
