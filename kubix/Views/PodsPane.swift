import KubixCore
import SwiftUI

/// One leading edge for the whole pane, shared with the native check so it asserts the value rather
/// than restating it. 16 is what `NSTableView.style = .inset` puts between the table's edge and its
/// first cell's text, so the content rows and the first column start at the same x.
enum PodsPaneMetrics {
    static let inset: CGFloat = 16
}

struct PodsPane: View {
    static let inset = PodsPaneMetrics.inset

    let store: AppStore
    let actions: AppActions

    private var subtitle: String {
        let table = store.podTable
        switch table.state {
        case .live: return table.subtitle + " · live"
        case .listed: return table.subtitle + " · waiting for live updates"
        case .connecting: return table.subtitle + " · connecting"
        case .failed: return table.subtitle + " · not updating"
        default: return table.subtitle
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PodsActions(store: store, actions: actions)
                .padding(.horizontal, Self.inset)
            if let diagnostic = store.namespaceDiagnostic {
                Text(diagnostic).font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, Self.inset)
            }
            if let picker = store.containerPicker {
                ContainerChoiceBar(presentation: picker, actions: actions)
                    .padding(.horizontal, Self.inset)
            }
            AuthSessionBanner(store: store, actions: actions)
            PodTableView(store: store, actions: actions)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The system's title, not a large one drawn in the content: this is where macOS puts what a
        // window is showing and how much of it, and it is the toolbar's own leading region.
        .navigationTitle("Pods")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { actions.refreshPods() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .help("List and watch this namespace again")
                Toggle("Wide", isOn: Binding(get: { store.podWide }, set: { actions.setPodWide($0) }))
                    .toggleStyle(.button)
                    .help("Show all server columns, including priority columns")
            }
        }
        .searchable(
            text: Binding(get: { store.podFilter }, set: { actions.setPodFilter($0) }),
            placement: .toolbar, prompt: "Search"
        )
    }
}

/// The page's controls, in reading order: what this list is scoped to, then the two actions that act
/// on the selected row. Left-aligned under the title, matched in height so the row reads as one group.
private struct PodsActions: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        HStack(spacing: 8) {
            NamespaceControl(store: store, actions: actions)
            RoundAction(
                symbol: "apple.terminal", help: "Open a shell in the selected pod's running regular container",
                disabled: store.podTable.selectedUID == nil
            ) {
                if let uid = store.podTable.selectedUID { actions.openPodShell(uid: uid) }
            }
            RoundAction(
                symbol: "doc.text", help: "Follow the selected pod's container logs",
                disabled: store.podTable.selectedUID == nil
            ) {
                actions.openPodLogs()
            }
            Spacer(minLength: 0)
        }
    }
}

private struct RoundAction: View {
    let symbol: String
    let help: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        // The toolbar's own controls are drawn at this weight, and the page's row reads as an
        // afterthought beside them at anything smaller.
        .controlSize(.extraLarge)
        .disabled(disabled)
        .help(help)
    }
}

/// Sign-in progress has to be visible from the pods pane too: a plugin can ask for browser approval
/// while the user is looking at a table, and the request is useless where it cannot be seen.
private struct AuthSessionBanner: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        if !store.focusedAuthenticationSessions.isEmpty || store.authenticationDiagnostic != nil {
            // Vertical padding only: horizontal padding here would indent this text past every other
            // row in the pane, which is the ragged edge this inset exists to remove.
            AuthProgressView(store: store, actions: actions)
                .padding(.horizontal, PodsPane.inset)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}

extension View {
    /// `.title` is macOS 15+; on 14 the toolbar keeps its title and the page simply reads it twice.
    @ViewBuilder func toolbarTitleHidden() -> some View {
        if #available(macOS 15.0, *) { toolbar(removing: .title) } else { self }
    }
}
