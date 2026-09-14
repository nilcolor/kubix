import KubixCore
import SwiftUI

/// One strip for every open session, shells and log tails alike, because they are the same thing to
/// the person switching between them: a live view of one container. The icon says which kind it is;
/// the row below names the pod it belongs to and offers its sibling containers.
struct ExecSessionDeck: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        VStack(spacing: 0) {
            SessionTabs(store: store, actions: actions)
            if let selection = store.selectedSession {
                SessionMeta(store: store, actions: actions, selection: selection)
                Divider()
                body(for: selection)
            } else {
                ContentUnavailableView("No open session", systemImage: "terminal")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Every session stays mounted: a terminal is a live process tree and a log tail is a live
    /// stream, so hiding one is an opacity change, never a teardown.
    @ViewBuilder private func body(for selection: SessionSelection) -> some View {
        ZStack {
            ForEach(store.execSessions.filter { !$0.isClosed }) { session in
                ShellBody(store: store, actions: actions, session: session, selected: selection == .shell(session.id))
                    .opacity(selection == .shell(session.id) ? 1 : 0)
                    .allowsHitTesting(selection == .shell(session.id))
                    .accessibilityHidden(selection != .shell(session.id))
            }
            ForEach(store.logSessions) { session in
                LogView(session: session, actions: actions)
                    .opacity(selection == .logs(session.id) ? 1 : 0)
                    .allowsHitTesting(selection == .logs(session.id))
                    .accessibilityHidden(selection != .logs(session.id))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SessionTabs: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        HStack(spacing: 6) {
            // Finder's shape: the tabs share the strip while they fit, and only scroll once they
            // cannot, so two sessions are not two small buttons against a wide empty bar.
            ViewThatFits(in: .horizontal) {
                strip(width: nil)
                ScrollView(.horizontal) { strip(width: SessionTab.minimum) }
                    .scrollIndicators(.never)
            }
            Button { actions.setDeckCollapsed(true) } label: {
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).frame(width: 14, height: 14)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .help("Collapse the session pane")
            .accessibilityIdentifier("collapse-deck")
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
    }

    private func strip(width: CGFloat?) -> some View {
        HStack(spacing: 6) {
            ForEach(store.openSessions) { selection in
                SessionTab(
                    actions: actions, selection: selection,
                    title: actions.sessionTarget(selection)?.pod ?? "",
                    detail: detail(selection), selected: store.selectedSession == selection, fixed: width
                )
            }
        }
        .padding(.vertical, 6)
    }

    /// Two sessions on one pod differ only by container, which the tab has no room for.
    private func detail(_ selection: SessionSelection) -> String {
        guard let target = actions.sessionTarget(selection) else { return "" }
        return "\(selection.isLogs ? "Logs" : "Shell") · \(target.pod) · \(target.container)"
    }
}

private struct SessionTab: View {
    static let minimum: CGFloat = 150

    let actions: AppActions
    let selection: SessionSelection
    let title: String
    let detail: String
    let selected: Bool
    let fixed: CGFloat?
    @State private var hovering = false

    var body: some View {
        Button { actions.selectSession(selection) } label: {
            HStack(spacing: 6) {
                Image(systemName: selection.isLogs ? "scroll" : "apple.terminal")
                    .font(.callout)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                // Finder reveals the close control on the tab under the pointer; a tab nobody is
                // pointing at keeps its name instead of a button.
                Button { actions.closeSession(selection) } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering || selected ? 1 : 0)
                .accessibilityLabel("Close session")
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(minWidth: Self.minimum, idealWidth: fixed, maxWidth: fixed ?? .infinity)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(fill)
                    .strokeBorder(selected ? Color(nsColor: .separatorColor) : .clear)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(detail)
        .accessibilityIdentifier("session-tab")
    }

    private var fill: Color {
        if selected { return Color(nsColor: .controlBackgroundColor) }
        return hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04)
    }
}

/// Where the session is, and the only other thing to ask about it: a different container of the same
/// pod. Choosing one focuses its session if it is already open, so the strip cannot collect
/// duplicates of the same target.
private struct SessionMeta: View {
    let store: AppStore
    let actions: AppActions
    let selection: SessionSelection
    @State private var switching = false

    var body: some View {
        HStack(spacing: 8) {
            if let target = actions.sessionTarget(selection) {
                Text("\(target.context.name) / \(target.namespace) / \(target.pod)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 8)
                if siblings.count > 1 {
                    Button { switching = true } label: {
                        HStack(spacing: 4) {
                            Text("Container:").foregroundStyle(.secondary)
                            Text(target.container).fontWeight(.medium)
                            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("container-switch")
                    .popover(isPresented: $switching, arrowEdge: .bottom) { switcher(current: target.container) }
                } else {
                    Text("Container: \(target.container)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 34)
    }

    private func switcher(current: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(selection.isLogs ? "Container logs" : "Container shell")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            ForEach(siblings, id: \.name) { container in
                SwitchChoice(
                    name: container.name, state: container.state.rawValue.capitalized,
                    detail: detail(container.name, current: current), isCurrent: container.name == current
                ) {
                    switching = false
                    guard container.name != current else { return }
                    actions.openSessionForContainer(selection, container: container.name)
                }
            }
        }
        .frame(width: 260)
        .padding(.bottom, 6)
        .focusEffectDisabled()
    }

    private func detail(_ name: String, current: String) -> String {
        if name == current { return "Current session" }
        return actions.hasOpenSession(selection, container: name) ? "Focus open tab" : "Open in a new tab"
    }

    /// The pod's own containers as validated when the session opened, filtered to what this kind of
    /// session can target: every declared container for logs, running regular ones for a shell.
    private var siblings: [PodDetails.Container] {
        switch selection {
        case .shell(let id):
            let containers = store.execSessions.first { $0.id == id }?.containers ?? []
            return containers.filter { $0.kind == .regular && $0.state == .running }
        case .logs(let id):
            return store.logSessions.first { $0.id == id }?.containers ?? []
        }
    }
}

private struct SwitchChoice: View {
    let name: String
    let state: String
    let detail: String
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    .opacity(isCurrent ? 1 : 0).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(state).font(.caption).foregroundStyle(state == "Running" ? Color.green : .secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.accentColor.opacity(0.14) : .clear).padding(.horizontal, 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("switch-choice-\(name)")
    }
}

private struct ShellBody: View {
    let store: AppStore
    let actions: AppActions
    let session: ExecSession
    let selected: Bool

    var body: some View {
        // Observing the revision mounts a ready surface before the bridge awaits its initial size.
        _ = store.surfaceRevision
        return VStack(alignment: .leading, spacing: 4) {
            if session.target.context.cluster.insecureSkipTLSVerify == true {
                Text("WARNING: TLS certificate verification disabled.").foregroundStyle(.red)
                    .padding(.horizontal, 11)
            }
            if !session.state.isRunning {
                HStack {
                    Text(status).font(.caption).textSelection(.enabled)
                    if case .finished(.failed(.authentication)) = session.state {
                        Button("Retry shell") { actions.retryShell(session.id) }.controlSize(.small)
                    }
                }
                .padding(.horizontal, 11).padding(.top, 4)
            }
            if let surface = actions.surface(for: session.id) as? GhosttySurfaceView {
                TerminalView(surface: surface, isSelected: selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var status: String {
        switch session.state {
        case .authenticating: "Waiting for credentials — sign in or retry above if needed."
        case .connecting: "Connecting authenticated exec…"
        case .running: "Connected — v5.channel.k8s.io"
        case .finished(.exited(let code)): "Remote command exited with code \(code)."
        case .finished(.failed(let failure)): "Session failed: \(failure.diagnostic)"
        case .finished(.cancelled): "Session cancelled."
        }
    }
}

/// The deck, out of the way but not gone: the sessions keep running and the table takes the space.
struct CollapsedDeckBar: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        Button { actions.setDeckCollapsed(false) } label: {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.bottomthird.inset.filled")
                Text(count == 1 ? "1 session" : "\(count) sessions")
                Spacer(minLength: 8)
                Text("Show").foregroundStyle(.secondary)
                Image(systemName: "chevron.up").font(.caption2).foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 11)
            .frame(height: 37)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("restore-deck")
    }

    private var count: Int { store.openSessions.count }
}

/// Drags the boundary between the pod table and the session deck. The height follows the absolute
/// cursor position rather than accumulated translation, so it cannot drift; the grab strip is taller
/// than the line it draws.
struct DeckResizeHandle: View {
    let actions: AppActions
    /// Where the pane starts in the same space the gesture reports. A drag's location is in window
    /// coordinates, which include the toolbar and everything else above the pane, so measuring the
    /// fraction without this offset jumps the boundary to a different point on mouse-down.
    let top: CGFloat
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
                        actions.setDeckFraction(DeckGeometry.fraction(at: value.location.y, top: top, total: total))
                    }
            )
    }
}
