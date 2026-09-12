import KubixCore
import SwiftUI

struct PodsPane: View {
    /// One leading edge for the whole pane. The table bleeds to the pane's edge and insets its own
    /// cells by the same amount, so its first column's text lines up with the controls above it
    /// instead of each element carrying its own padding.
    /// 16 because that is what `NSTableView.style = .inset` puts between the table's edge and its
    /// first cell's text; matching it exactly is what makes the column read as one edge.
    static let inset: CGFloat = 16

    let store: AppStore
    let actions: AppActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // Flexible, not fixed: a hard width here becomes part of the detail pane's minimum,
                // which the split view then takes out of the sidebar column.
                NamespaceCombo(store: store, actions: actions).frame(minWidth: 150, maxWidth: 240, minHeight: 22, maxHeight: 22)
                Toggle("Wide", isOn: Binding(get: { store.podWide }, set: { actions.setPodWide($0) }))
                    .toggleStyle(.checkbox)
                    .help("Show all server columns, including priority columns")
                Button("Shell") { if let uid = store.podTable.selectedUID { actions.openPodShell(uid: uid) } }
                    .disabled(store.podTable.selectedUID == nil)
                    .help("Open a shell in the selected pod's running regular container")
                Button("Logs") { actions.openPodLogs() }
                    .disabled(store.podTable.selectedUID == nil)
                Spacer(minLength: 12)
                PodSearchField(store: store, actions: actions)
            }
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
        // The detail pane must claim the slack, or the split view hands every extra point to the
        // sidebar and its width tracks the window instead of staying put.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PodSearchField: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: Binding(get: { store.podFilter }, set: { actions.setPodFilter($0) }))
                .textFieldStyle(.plain)
                .accessibilityIdentifier("pod-filter")
            // The clear control keeps its space when empty, so neighbouring controls never shift.
            Button { actions.setPodFilter("") } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(store.podFilter.isEmpty ? 0 : 1)
                .disabled(store.podFilter.isEmpty)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        .frame(minWidth: 130, maxWidth: 240)
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
