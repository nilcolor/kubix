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
            PodsHeader(store: store, actions: actions)
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
        // Native controls in the native place: the system draws the toolbar's material, which is what
        // a hand-built row of buttons inside the content area can never match.
        // The count belongs beside the window title, where macOS puts a collection's size, rather
        // than as another line of body text above the table.
        .navigationTitle("Pods")
        .navigationSubtitle(store.podTable.subtitle)
        // The page draws its own title, and the toolbar's copy of it sits in the leading region that
        // spans the sidebar column, where it crowds whatever else is placed there.
        .toolbarTitleHidden()
        .toolbar {
            ToolbarItemGroup {
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

/// The page's own header: what this list is, how current it is, and the two actions that act on the
/// selected row. Round icon buttons rather than toolbar text, so a per-selection action sits with the
/// selection rather than with the view-wide controls.
private struct PodsHeader: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pods").font(.largeTitle.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
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
            }
        }
    }

    private var subtitle: String {
        let table = store.podTable
        let scope = table.subtitle
        switch table.state {
        case .live: return scope + " · live"
        case .listed: return scope + " · waiting for live updates"
        case .connecting: return scope + " · connecting"
        case .failed: return scope + " · not updating"
        default: return scope
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
        .controlSize(.large)
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
