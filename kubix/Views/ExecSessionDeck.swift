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
                            Button("Shell: " + session.target.pod + "/" + session.target.container) { actions.selectShell(session.id) }
                                .fontWeight(isSelected(session.id) ? .bold : .regular)
                            Button { actions.closeShell(session.id) } label: { Image(systemName: "xmark") }
                                .help("Close this session")
                        }
                    }
                    ForEach(store.logSessions) { session in
                        HStack(spacing: 4) {
                            Button("Logs: " + session.target.pod + "/" + session.target.container.name) { actions.selectLog(session.id) }
                                .fontWeight(store.selectedLogSessionID == session.id ? .bold : .regular)
                            Button { actions.closeLog(session.id) } label: { Image(systemName: "xmark") }
                                .help("Close this log session")
                        }
                    }
                }.padding(8)
            }.fixedSize(horizontal: false, vertical: true)
            ZStack {
                if sessions.isEmpty && store.logSessions.isEmpty {
                    ContentUnavailableView("Connect to a known container", systemImage: "terminal")
                }
                ForEach(sessions) { session in
                    sessionView(session, selected: isSelected(session.id))
                        .opacity(isSelected(session.id) ? 1 : 0)
                        .allowsHitTesting(isSelected(session.id))
                        .accessibilityHidden(!isSelected(session.id))
                }
                ForEach(store.logSessions) { session in
                    LogView(session: session, actions: actions)
                        .opacity(session.id == store.selectedLogSessionID ? 1 : 0)
                        .allowsHitTesting(session.id == store.selectedLogSessionID)
                        .accessibilityHidden(session.id != store.selectedLogSessionID)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func isSelected(_ id: UUID) -> Bool { store.selectedLogSessionID == nil && store.selectedExecSessionID == id }

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

/// Drags the boundary between the pod table and the session deck. Same shape as the sidebar handle:
/// the width follows the absolute cursor position rather than accumulated translation, and the grab
/// strip is taller than the line it draws.
struct DeckResizeHandle: View {
    let actions: AppActions
    let total: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .overlay { strip }
    }

    private var strip: some View {
        Color.clear
            .frame(height: 10)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        guard total > 0 else { return }
                        actions.setDeckFraction(1 - value.location.y / total)
                    }
            )
    }
}
