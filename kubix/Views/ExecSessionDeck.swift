import KubixCore
import SwiftUI

struct ExecSessionDeck: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        let sessions = store.execSessions.filter { !$0.isClosed }
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(sessions) { session in
                        HStack(spacing: 4) {
                            Button(session.target.pod + "/" + session.target.container) { actions.selectShell(session.id) }
                                .fontWeight(store.selectedExecSessionID == session.id ? .bold : .regular)
                            Button { actions.closeShell(session.id) } label: { Image(systemName: "xmark") }
                                .help("Close this session")
                        }
                    }
                }.padding(8)
            }.fixedSize(horizontal: false, vertical: true)
            ZStack {
                if sessions.isEmpty {
                    ContentUnavailableView("Connect to a known container", systemImage: "terminal")
                }
                ForEach(sessions) { session in
                    sessionView(session, selected: session.id == store.selectedExecSessionID)
                        .opacity(session.id == store.selectedExecSessionID ? 1 : 0)
                        .allowsHitTesting(session.id == store.selectedExecSessionID)
                        .accessibilityHidden(session.id != store.selectedExecSessionID)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sessionView(_ session: ExecSession, selected: Bool) -> some View {
        // Observing the revision mounts a ready surface before the bridge awaits its initial size.
        _ = store.surfaceRevision
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(session.target.context.name) / \(session.target.namespace) / \(session.target.pod) / \(session.target.container)")
                .font(.caption).padding(.horizontal, 8)
            if session.target.context.cluster.insecureSkipTLSVerify == true {
                Text("WARNING: TLS certificate verification disabled.").foregroundStyle(.red)
            }
            HStack {
                Text(status(session.state)).textSelection(.enabled)
                if case .finished(.failed(.authentication)) = session.state {
                    Button("Retry shell") { actions.retryShell(session.id) }
                }
            }.padding(.horizontal, 8)
            if let surface = actions.surface(for: session.id) as? GhosttySurfaceView {
                TerminalView(surface: surface, isSelected: selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func status(_ state: ExecSession.State) -> String {
        switch state {
        case .authenticating: "Waiting for credentials — sign in or retry above if needed."
        case .connecting: "Connecting authenticated exec…"
        case .running: "Connected — v5.channel.k8s.io"
        case .finished(.exited(let code)): "Remote command exited with code \(code)."
        case .finished(.failed(let failure)): "Session failed: \(failure.diagnostic)"
        case .finished(.cancelled): "Session cancelled."
        }
    }
}
