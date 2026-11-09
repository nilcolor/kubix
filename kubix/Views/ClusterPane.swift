import KubixCore
import SwiftUI

/// The pane for a selected cluster row. Every auth action here still acts on `selectedContext`, which
/// is this cluster — the pane on screen and the focused context are the same thing by construction.
struct ClusterPane: View {
    let cluster: ClusterStatus
    let store: AppStore
    let actions: AppActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ClusterHeader(cluster: cluster, actions: actions)
                if cluster.context.cluster.insecureSkipTLSVerify == true {
                    WarningBanner(
                        title: "TLS certificate verification is disabled",
                        detail: "This context trusts any certificate the server presents."
                    )
                }
                ClusterTiles(cluster: cluster)
                WorkloadSummary(overview: cluster.overview)
                ClusterDetails(cluster: cluster)
                PluginSection(store: store, actions: actions)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("Overview")
        .navigationSubtitle(cluster.context.name)
        .toolbarTitleHidden()
    }
}

private struct ClusterHeader: View {
    let cluster: ClusterStatus
    let actions: AppActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(cluster.context.name).font(.largeTitle.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 12)
                action
            }
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(stateLabel).foregroundStyle(stateColor)
                if let version = cluster.serverVersion {
                    Text("Kubernetes \(version)").foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .font(.callout)
            if case .failed(let reason) = cluster.state {
                Text(reason).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }

    /// A labelled capsule rather than an icon-only circle: this tears down a live watch, and a bare
    /// glyph does not say so.
    @ViewBuilder private var action: some View {
        switch cluster.state {
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…").font(.callout).foregroundStyle(.secondary)
            }
        case .connected:
            Button("Disconnect") { actions.disconnect(contextNamed: cluster.id) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        case .disconnected, .failed:
            Button(cluster.state.isFailed ? "Retry Connect" : "Connect") {
                actions.connect(contextNamed: cluster.id)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var stateLabel: String {
        switch cluster.state {
        case .disconnected: "Not connected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .failed: "Connection failed"
        }
    }

    private var dotColor: Color {
        switch cluster.state {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .orange
        case .disconnected: .secondary
        }
    }

    private var stateColor: Color {
        if case .connected = cluster.state { return .green }
        if case .failed = cluster.state { return .orange }
        return .secondary
    }
}

private struct WarningBanner: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }
}

private struct ClusterTiles: View {
    let cluster: ClusterStatus

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Tile(title: "Nodes", reading: nodes, unit: "ready")
            Divider().frame(height: 54)
            Tile(title: "Namespaces", value: namespaceCount, unit: "listed", detail: namespaceDetail)
            Divider().frame(height: 54)
            Tile(title: "Events", reading: events, unit: "warnings")
        }
    }

    private var nodes: TileReading {
        TileReading(cluster.overview.nodes) { counts in
            let notReady = counts.total - counts.ready
            return (String(counts.ready), notReady == 0 ? "of \(counts.total)" : "of \(counts.total) · \(notReady) not ready")
        }
    }

    /// The apiserver keeps events for its event TTL, an hour by default, so this is not a lifetime total.
    private var events: TileReading {
        TileReading(cluster.overview.warningEvents) { (String($0), "Still retained by the server") }
    }

    private var namespaceCount: String? {
        guard case .listed(let names) = cluster.namespaces else { return nil }
        return String(names.count)
    }

    private var namespaceDetail: String? {
        switch cluster.namespaces {
        case .listed: nil
        case .unavailable: "Listing not permitted"
        case .unknown: cluster.state == .connected ? "Listing…" : "Connect to list"
        }
    }
}

private struct TileReading {
    var value: String?
    var detail: String?

    init<Value: Equatable & Sendable>(_ reading: OverviewValue<Value>, format: (Value) -> (String, String)) {
        switch reading {
        case .unknown: break
        case .value(let value): (self.value, detail) = format(value)
        default: (value, detail) = ("—", reading.problem)
        }
    }
}

/// A number this app has not asked the server for must not look like one it has, so an unknown value
/// is a grey bar. The unit word stays: it is what the number will mean, and it reads better than a
/// sentence explaining the absence.
private struct Tile: View {
    let title: String
    let value: String?
    let unit: String
    let detail: String?

    init(title: String, value: String?, unit: String, detail: String?) {
        self.title = title
        self.value = value
        self.unit = unit
        self.detail = detail
    }

    init(title: String, reading: TileReading, unit: String) {
        self.init(title: title, value: reading.value, unit: unit, detail: reading.detail)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let value {
                    Text(value).font(.system(size: 30, weight: .semibold))
                } else {
                    Skeleton(width: 52, height: 22, shade: 0.16)
                }
                Text(unit).font(.callout).foregroundStyle(.secondary)
            }
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            } else {
                Skeleton(width: 96, height: 8, shade: 0.10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

struct Skeleton: View {
    let width: CGFloat?
    let height: CGFloat
    let shade: Double

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2.5)
            .fill(Color.secondary.opacity(shade))
            .frame(width: width, height: height)
    }
}

private struct ClusterDetails: View {
    let cluster: ClusterStatus
    @State private var expanded = true

    var body: some View {
        DisclosureGroup("Cluster details", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Row(label: "Context", value: cluster.context.name)
                Row(label: "Cluster", value: cluster.context.clusterName)
                Row(label: "Server", value: cluster.context.cluster.server)
                Row(label: "Version", value: cluster.serverVersion ?? "Not reported")
                Row(label: "User", value: cluster.context.userName ?? "Anonymous")
                Row(label: "Default namespace", value: cluster.context.namespace)
                if let source = cluster.context.sourceFile {
                    Row(label: "From", value: source.path)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
        .font(.title3.weight(.semibold))
    }

    private struct Row: View {
        let label: String
        let value: String

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).font(.callout).foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .leading)
                Text(value).font(.callout).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
        }
    }
}

/// Setup detail, so it sits below the facts and starts collapsed once a plugin is resolving.
private struct PluginSection: View {
    let store: AppStore
    let actions: AppActions
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Credential plugin", isExpanded: $expanded) {
            let plugin = store.pluginPresentation
            VStack(alignment: .leading, spacing: 8) {
                if let executable = plugin.executable {
                    Text("\(executable) (\(plugin.source ?? "configured executable"))")
                        .font(.callout).textSelection(.enabled)
                }
                if let profile = plugin.profile {
                    Text("Bound AWS profile: \(profile)").font(.callout)
                }
                if !plugin.canSignIn, plugin.executable != nil {
                    Text("The configured plugin can acquire credentials or request browser sign-in. It is not replaced with AWS CLI SSO login.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let diagnostic = plugin.diagnostic {
                    Text(diagnostic).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { buttons }
                    VStack(alignment: .leading, spacing: 6) { buttons }
                }
                AuthProgressView(store: store, actions: actions, sessions: store.focusedAuthenticationSessions)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
        .font(.title3.weight(.semibold))
    }

    @ViewBuilder private var buttons: some View {
        let plugin = store.pluginPresentation
        Button("Authenticate configured plugin") { Task { await actions.authenticateSelectedContext() } }
            .disabled(store.selectedContext?.user?.exec == nil || plugin.executable == nil)
        if plugin.canSignIn {
            Button("Sign in with AWS") { Task { await actions.signInSelectedContext() } }
            Toggle("Use device code", isOn: Binding(get: { store.useDeviceCode }, set: { actions.setUseDeviceCode($0) }))
                .toggleStyle(.checkbox)
        }
        Button("Configure Plugin Path") { actions.setShowingSettings(true) }
    }
}

private extension ClusterStatus.State {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
