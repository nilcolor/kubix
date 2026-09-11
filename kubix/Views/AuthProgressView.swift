import KubixCore
import SwiftUI

/// Live sign-in sessions only. The buttons that *start* authentication belong to a cluster, so they
/// live in `ClusterPane`; this view is shown wherever progress has to be visible.
struct AuthProgressView: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.selectedContext?.user?.exec != nil, !store.visibleAuthenticationSessions.isEmpty {
                Text("Complete any browser approval, then choose Retry authentication if the plugin reports a failure.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let diagnostic = store.authenticationDiagnostic {
                Text(diagnostic).foregroundStyle(.orange).textSelection(.enabled)
            }
            ForEach(store.visibleAuthenticationSessions, id: \.id) { session in
                progress(AuthPresentation(session))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
