import KubixCore
import SwiftUI

struct AuthProgressView: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let plugin = store.pluginPresentation
            HStack {
                Button("Authenticate configured plugin") { Task { await actions.authenticateSelectedContext() } }
                    .disabled(store.selectedContext?.user?.exec == nil || plugin.executable == nil)
                if plugin.canSignIn {
                    Button("Sign in with AWS") { Task { await actions.signInSelectedContext() } }
                    Toggle("Use device code", isOn: Binding(get: { store.useDeviceCode }, set: { actions.setUseDeviceCode($0) }))
                        .toggleStyle(.checkbox)
                }
                Button("Configure Plugin Path") { actions.setShowingSettings(true) }
            }
            if !plugin.canSignIn, plugin.executable != nil {
                Text("The configured plugin can acquire credentials or request browser sign-in. It is not replaced with AWS CLI SSO login.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.selectedContext?.user?.exec != nil {
                Text("Complete any browser approval, then choose Retry authentication if the plugin reports a failure.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let executable = plugin.executable {
                Text("\(executable) (\(plugin.source ?? "configured executable"))").font(.caption).textSelection(.enabled)
            }
            if let profile = plugin.profile { Text("Bound AWS profile: \(profile)").font(.caption) }
            if let diagnostic = plugin.diagnostic { Text(diagnostic).foregroundStyle(.orange) }
            if let diagnostic = store.authenticationDiagnostic { Text(diagnostic).foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.authenticationSessions.values.sorted { $0.id.uuidString < $1.id.uuidString }, id: \.id) { session in
                        progress(AuthPresentation(session))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: store.authenticationSessions.isEmpty ? 0 : 150)
        }
    }

    private func progress(_ presentation: AuthPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(presentation.title).font(.subheadline.bold())
            Text(presentation.status).font(.caption)
            if !presentation.instructions.isEmpty {
                Text(presentation.instructions).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            HStack {
                if presentation.authorizationURL != nil {
                    Button("Open Browser") { Task { await actions.openAuthorizationURL(operationID: presentation.session.id) } }
                }
                if presentation.canCancel {
                    Button("Cancel") { Task { await actions.cancelAuthentication(operationID: presentation.session.id) } }
                }
                if presentation.canRetry {
                    Button("Retry authentication") { Task { try? await actions.retryAuthentication(operationID: presentation.session.id) } }
                }
            }
        }
    }
}
