import KubixCore
import SwiftUI

struct ClusterSidebar: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                ForEach(store.clusters) { cluster in
                    ClusterSection(cluster: cluster, actions: actions)
                }
            }
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

private struct ClusterSection: View {
    let cluster: ClusterStatus
    let actions: AppActions
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if cluster.state == .connected {
                Text("Workload")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
                Label("Pods", systemImage: "shippingbox")
                    .tag(SidebarSelection.pods(cluster.id))
            } else {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(cluster.state.isFailed ? .orange : .secondary)
                    .textSelection(.enabled)
                    .selectionDisabled()
            }
        } label: {
            ClusterRow(cluster: cluster, actions: actions)
                .tag(SidebarSelection.cluster(cluster.id))
        }
    }

    private var detail: String {
        switch cluster.state {
        case .failed(let reason): reason
        case .connecting: "Connecting…"
        default: "Not connected. Connect to browse this cluster."
        }
    }
}

private struct ClusterRow: View {
    let cluster: ClusterStatus
    let actions: AppActions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            StateDot(state: cluster.state)
            Text(cluster.context.name).lineLimit(1).truncationMode(.middle).help(cluster.context.name)
            if cluster.context.cluster.insecureSkipTLSVerify == true {
                Image(systemName: "lock.open.trianglebadge.exclamationmark")
                    .foregroundStyle(.red)
                    .help("TLS certificate verification is disabled for this context.")
            }
            Spacer(minLength: 4)
            action
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if cluster.state == .connected {
                Button("Disconnect") { actions.disconnect(contextNamed: cluster.id) }
            } else {
                Button(cluster.state.isFailed ? "Retry Connect" : "Connect") { actions.connect(contextNamed: cluster.id) }
            }
        }
    }

    @ViewBuilder private var action: some View {
        switch cluster.state {
        case .connecting:
            ProgressView().controlSize(.small)
        case .connected:
            // Disconnecting is rare and destructive to a live watch, so it stays behind hover.
            Button("Disconnect") { actions.disconnect(contextNamed: cluster.id) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
        case .disconnected, .failed:
            Button(cluster.state.isFailed ? "Retry" : "Connect") { actions.connect(contextNamed: cluster.id) }
                .controlSize(.small)
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
        case .failed: "Connection failed"
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
                Text("Kubix v0.1").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Reload kubeconfig") { Task { await actions.loadConfiguration() } }
                    .controlSize(.small)
                    .disabled(store.isLoadingConfiguration)
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
