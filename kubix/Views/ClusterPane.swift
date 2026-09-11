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
            VStack(alignment: .leading, spacing: 12) {
                header
                if cluster.context.cluster.insecureSkipTLSVerify == true {
                    Text("WARNING: TLS certificate verification is disabled for this context.")
                        .foregroundStyle(.red)
                }
                Divider()
                PluginDetails(store: store, actions: actions)
                AuthProgressView(store: store, actions: actions)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    @ViewBuilder private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(cluster.context.name).font(.title2)
                Text(status).font(.callout).foregroundStyle(statusColor).textSelection(.enabled)
            }
            Spacer(minLength: 12)
            connectAction
        }
    }

    @ViewBuilder private var connectAction: some View {
        switch cluster.state {
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            }
        case .connected:
            Button("Disconnect") { actions.disconnect(contextNamed: cluster.id) }
        case .disconnected:
            Button("Connect") { actions.connect(contextNamed: cluster.id) }.keyboardShortcut(.defaultAction)
        case .failed:
            Button("Retry Connect") { actions.connect(contextNamed: cluster.id) }.keyboardShortcut(.defaultAction)
        }
    }

    private var status: String {
        switch cluster.state {
        case .disconnected: "Not connected. Connect acquires credentials and checks the apiserver; it does not list pods."
        case .connecting: "Acquiring credentials and checking the apiserver…"
        case .connected: "Connected. Choose Pods in the sidebar to browse a namespace."
        case .failed(let reason): reason
        }
    }

    private var statusColor: Color {
        if case .failed = cluster.state { return .orange }
        return .secondary
    }
}

private struct PluginDetails: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        let plugin = store.pluginPresentation
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .leading, spacing: 6) { buttons }
            }
            if !plugin.canSignIn, plugin.executable != nil {
                Text("The configured plugin can acquire credentials or request browser sign-in. It is not replaced with AWS CLI SSO login.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let executable = plugin.executable {
                Text("\(executable) (\(plugin.source ?? "configured executable"))").font(.caption).textSelection(.enabled)
            }
            if let profile = plugin.profile { Text("Bound AWS profile: \(profile)").font(.caption) }
            if let diagnostic = plugin.diagnostic { Text(diagnostic).foregroundStyle(.orange) }
        }
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
