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

    private var settling: Bool {
        let state = store.podTable.state
        return !store.rows.isEmpty && (state == .connecting || state == .listed)
    }

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
                Button { actions.refreshPods() } label: {
                    // A watch that is still settling with rows already on screen has nowhere else to
                    // say so: the table keeps its rows and the toolbar keeps the same geometry.
                    if settling {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .help(settling ? "Listing and watching this namespace" : "List and watch this namespace again")
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
                symbol: "apple.terminal", help: "Open a shell in one of the selected pod's containers",
                disabled: store.podTable.selectedUID == nil, busy: isChoosing(.shell)
            ) {
                if let uid = store.podTable.selectedUID { actions.openPodShell(uid: uid) }
            }
            .popover(isPresented: menu(for: .shell), arrowEdge: .bottom) {
                ContainerMenu(store: store, actions: actions)
            }
            RoundAction(
                symbol: "doc.text", help: "Follow one of the selected pod's container logs",
                disabled: store.podTable.selectedUID == nil, busy: isChoosing(.logs)
            ) {
                if let uid = store.podTable.selectedUID { actions.openPodLogs(uid: uid) }
            }
            .popover(isPresented: menu(for: .logs), arrowEdge: .bottom) {
                ContainerMenu(store: store, actions: actions)
            }
            Spacer(minLength: 0)
        }
    }

    /// The menu belongs to the button that asked for it, and dismissing it is the same as cancelling
    /// the choice — there is no half-open state where a pod is picked but nothing was asked for.
    private func menu(for purpose: ContainerPickerPresentation.Purpose) -> Binding<Bool> {
        Binding(
            get: { store.containerPicker?.purpose == purpose },
            set: { shown in
                guard !shown, let picker = store.containerPicker, picker.purpose == purpose else { return }
                switch purpose {
                case .shell: actions.cancelPodShell(selectionID: picker.id)
                case .logs: actions.cancelPodLogs(selectionID: picker.id)
                }
            }
        )
    }

    private func isChoosing(_ purpose: ContainerPickerPresentation.Purpose) -> Bool {
        store.isLoadingPodDetails && store.containerPicker == nil && pending == purpose
    }

    private var pending: ContainerPickerPresentation.Purpose? {
        store.podTable.selectedUID == nil ? nil : store.pendingContainerPurpose
    }
}

private struct RoundAction: View {
    let symbol: String
    let help: String
    let disabled: Bool
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // The pod is fetched before its containers can be listed, so the button says so in place
            // rather than leaving the click unanswered for the length of a request.
            if busy {
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
            } else {
                Image(systemName: symbol).frame(width: 16, height: 16)
            }
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
        let sessions = store.attentionAuthenticationSessions
        if !sessions.isEmpty || store.authenticationDiagnostic != nil {
            // Vertical padding only: horizontal padding here would indent this text past every other
            // row in the pane, which is the ragged edge this inset exists to remove.
            AuthProgressView(store: store, actions: actions, sessions: sessions)
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
