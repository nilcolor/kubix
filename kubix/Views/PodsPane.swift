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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        // Native controls in the native place: the system draws the toolbar's material, which is what
        // a hand-built row of buttons inside the content area can never match.
        // The count belongs beside the window title, where macOS puts a collection's size, rather
        // than as another line of body text above the table.
        .navigationTitle("Pods")
        .navigationSubtitle(store.podTable.subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                NamespaceCombo(store: store, actions: actions).frame(width: 200, height: 22)
            }
            ToolbarItemGroup {
                Toggle("Wide", isOn: Binding(get: { store.podWide }, set: { actions.setPodWide($0) }))
                    .toggleStyle(.button)
                    .help("Show all server columns, including priority columns")
                Button("Shell") { if let uid = store.podTable.selectedUID { actions.openPodShell(uid: uid) } }
                    .disabled(store.podTable.selectedUID == nil)
                    .help("Open a shell in the selected pod's running regular container")
                Button("Logs") { actions.openPodLogs() }
                    .disabled(store.podTable.selectedUID == nil)
            }
        }
        .searchable(
            text: Binding(get: { store.podFilter }, set: { actions.setPodFilter($0) }),
            placement: .toolbar, prompt: "Search"
        )
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
