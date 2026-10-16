import KubixCore
import SwiftUI

/// One leading edge for the whole pane, shared with the native check so it asserts the value rather
/// than restating it. 16 is what `NSTableView.style = .inset` puts between the table's edge and its
/// first cell's text, so the content rows and the first column start at the same x.
enum ListPaneMetrics {
    static let inset: CGFloat = 16
}

struct ResourceListPane: View {
    static let inset = ListPaneMetrics.inset

    /// From the sidebar selection rather than the store's slot, so the title can never lag a
    /// selection the user has already made.
    let kind: ResourceKind
    let store: AppStore
    let actions: AppActions

    private var settling: Bool {
        let state = store.listTable.state
        return !store.rows.isEmpty && (state == .connecting || state == .listed)
    }

    private var subtitle: String {
        let table = store.listTable
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
            ListActions(kind: kind, store: store, actions: actions)
                .padding(.horizontal, Self.inset)
            // Everything that explains an action floats over the table's foot rather than taking a
            // row: a message that appears for the length of a request moved every row under it.
            ResourceTableView(kind: kind, store: store, actions: actions)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 8) {
                        AuthSessionBanner(store: store, actions: actions)
                        PodDiagnostics(store: store, actions: actions)
                    }
                    .padding(.bottom, 12)
                }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The system's title, not a large one drawn in the content: this is where macOS puts what a
        // window is showing and how much of it, and it is the toolbar's own leading region.
        .navigationTitle(kind.title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { actions.refreshList(kind) } label: {
                    // A watch that is still settling with rows already on screen has nowhere else to
                    // say so: the table keeps its rows and the toolbar keeps the same geometry.
                    if settling {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .help(settling ? "Listing and watching this namespace" : "List and watch this namespace again")
                Toggle("Wide", isOn: Binding(get: { store.listWide }, set: { actions.setListWide($0) }))
                    .toggleStyle(.button)
                    .help("Show all server columns, including priority columns")
            }
        }
        .searchable(
            text: Binding(get: { store.listFilter }, set: { actions.setListFilter($0) }),
            placement: .toolbar, prompt: "Search"
        )
        // A sheet rather than a confirmation dialog: it is modal for the whole window, toolbar
        // included, and its buttons can be the ones the design names.
        .sheet(item: Binding(
            get: { store.podDeletion },
            set: { if $0 == nil { actions.podDeletionDialogClosed() } }
        )) { deletion in
            PodDeletionDialog(deletion: deletion, actions: actions)
        }
    }
}

/// The page's controls, in reading order: what this list is scoped to, the two actions that act on
/// the selected row, then the one that writes, set apart. Left-aligned under the title, matched in height so the row reads as one group.
private struct ListActions: View {
    let kind: ResourceKind
    let store: AppStore
    let actions: AppActions

    var body: some View {
        HStack(spacing: 8) {
            NamespaceControl(store: store, actions: actions)
            if kind.supportsShell {
                RoundAction(
                    symbol: "apple.terminal", help: "Open a shell in one of the selected pod's containers",
                    disabled: store.listTable.selectedUID == nil, busy: isChoosing(.shell)
                ) {
                    if let uid = store.listTable.selectedUID { actions.openPodShell(uid: uid) }
                }
                .popover(isPresented: menu(for: .shell), arrowEdge: .bottom) {
                    ContainerMenu(store: store, actions: actions)
                }
            }
            if kind.supportsLogs {
                RoundAction(
                    symbol: "doc.text", help: logsHelp,
                    disabled: store.listTable.selectedUID == nil, busy: isChoosing(.logs)
                ) {
                    guard let uid = store.listTable.selectedUID else { return }
                    if kind == .deployments {
                        actions.openDeploymentLogs(uid: uid)
                    } else {
                        actions.openPodLogs(uid: uid)
                    }
                }
                .popover(isPresented: menu(for: .logs), arrowEdge: .bottom) {
                    ContainerMenu(store: store, actions: actions)
                }
            }
            if kind.supportsDelete, actions.offersPodDeletion {
                Divider().frame(height: 22).padding(.horizontal, 4)
                deleteButton
            }
            Spacer(minLength: 0)
        }
        // The row takes its height from its tallest control, so the picker can stretch to it.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var deleteButton: some View {
        let selected = store.listTable.selectedUIDs
        return Button { actions.requestPodDeletion(uids: selected) } label: {
            Label(selected.count > 1 ? "Delete \(selected.count) Pods…" : "Delete Pod…", systemImage: "trash")
                // On the label, not the button: a bordered button tints its own fill from it.
                .foregroundStyle(selected.isEmpty ? Color.secondary : Color.red)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.extraLarge)
        .disabled(selected.isEmpty)
        .help(selected.count > 1 ? "Delete the selected pods" : "Delete the selected pod")
    }

    private var logsHelp: String {
        kind.supportsShell
            ? "Follow one of the selected pod's container logs"
            : "Follow the logs of every pod of the selected deployment"
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
        store.listTable.selectedUID == nil ? nil : store.pendingContainerPurpose
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
            AuthProgressView(store: store, actions: actions, sessions: sessions)
                .padding(12)
                .frame(maxWidth: 560, alignment: .leading)
                .floatingCard()
        }
    }
}

extension View {
    /// The page draws its own title; this drops the toolbar's copy of it.
    func toolbarTitleHidden() -> some View { toolbar(removing: .title) }
}
