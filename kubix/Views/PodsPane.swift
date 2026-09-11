import KubixCore
import SwiftUI

struct PodsPane: View {
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
                Button("Logs") { actions.openPodLogs() }
                    .disabled(store.podTable.selectedUID == nil)
                Spacer(minLength: 12)
                PodSearchField(store: store, actions: actions)
            }
            if let diagnostic = store.namespaceDiagnostic {
                Text(diagnostic).font(.caption).foregroundStyle(.orange)
            }
            AuthSessionBanner(store: store, actions: actions)
            PodTableView(store: store, actions: actions)
        }
        .padding(10)
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
            AuthProgressView(store: store, actions: actions)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }
}
