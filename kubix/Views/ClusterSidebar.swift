import KubixCore
import SwiftUI

struct ClusterSidebar: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section("Clusters") {
                    ForEach(store.clusters) { cluster in
                        ClusterSection(cluster: cluster, actions: actions)
                    }
                }
            }
            // Explicit, because the sidebar look is no longer inherited from a NavigationSplitView.
            .listStyle(.sidebar)
            .onKeyPress(.return) { connectSelected() }
            Divider()
            SidebarFooter(store: store, actions: actions)
        }
    }

    private var selection: Binding<SidebarSelection?> {
        Binding(get: { store.sidebarSelection }, set: { value in value.map(actions.selectSidebar) })
    }

    /// Return on a selected row is the keyboard route to Connect: a hover-revealed button alone is
    /// unreachable without a pointer.
    private func connectSelected() -> KeyPress.Result {
        guard let name = store.sidebarSelection?.clusterName,
              let cluster = store.clusters.first(where: { $0.id == name }), cluster.state != .connected else {
            return .ignored
        }
        actions.connect(contextNamed: name)
        return .handled
    }
}

/// Hand-rolled disclosure rather than a `DisclosureGroup`: the cluster's own row is a selection —
/// clicking it opens the cluster overview — and a group's label row cannot carry a tag.
///
/// Only a connected cluster discloses anything. A disconnected one is a single row with no chevron:
/// with this many contexts, a per-row Connect button and a repeated "not connected" sentence are the
/// bulk of the sidebar, and both say what the overview pane says with room to explain it.
private struct ClusterSection: View {
    let cluster: ClusterStatus
    let actions: AppActions
    @State private var expanded = true

    var body: some View {
        ClusterRow(cluster: cluster, expanded: $expanded, actions: actions)
            .tag(SidebarSelection.cluster(cluster.id))
        if cluster.state == .connected, expanded {
            Label("Pods", systemImage: "shippingbox")
                .padding(.leading, Self.indent)
                .tag(SidebarSelection.list(cluster.id, .pods))
        }
    }

    private static let indent: CGFloat = 20
}

private struct ClusterRow: View {
    let cluster: ClusterStatus
    @Binding var expanded: Bool
    let actions: AppActions

    var body: some View {
        HStack(spacing: 6) {
            if cluster.state == .connected {
                Button { expanded.toggle() } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse" : "Expand")
            } else {
                Spacer().frame(width: 10)
            }
            StateDot(state: cluster.state)
            Text(cluster.context.name).lineLimit(1).help(cluster.context.name)
            if cluster.context.cluster.insecureSkipTLSVerify == true {
                Image(systemName: "lock.open.trianglebadge.exclamationmark")
                    .foregroundStyle(.red)
                    .help("TLS certificate verification is disabled for this context.")
            }
            Spacer(minLength: 4)
            if cluster.state == .connecting { ProgressView().controlSize(.small) }
        }
        .contextMenu {
            if cluster.state == .connected {
                Button("Disconnect") { actions.disconnect(contextNamed: cluster.id) }
            } else {
                Button(cluster.state.isFailed ? "Retry Connect" : "Connect") { actions.connect(contextNamed: cluster.id) }
            }
        }
    }
}

private struct StateDot: View {
    let state: ClusterStatus.State

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(label)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch state {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .orange
        case .disconnected: .secondary
        }
    }

    private var label: String {
        switch state {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .failed(let reason): "Connection failed: \(reason)"
        case .disconnected: "Not connected"
        }
    }
}

private struct SidebarFooter: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(store.configurationDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Text(diagnostic).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                Text("Kubix 0.1").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { Task { await actions.loadConfiguration() } } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .disabled(store.isLoadingConfiguration)
                .help("Reload kubeconfig")
            }
        }
        .padding(8)
    }
}

private extension ClusterStatus.State {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
