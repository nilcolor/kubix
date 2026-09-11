import KubixCore
import SwiftUI

struct ContentView: View {
    let composition: AppComposition
    var body: some View {
        let store = composition.store
        let actions = composition.actions
        // Not a NavigationSplitView. Given a width range it divides a window resize between both
        // columns, so the sidebar shrank until it clipped the chevron and the start of every cluster
        // name; given a fixed width it stops reacting to that width changing at all, so the column
        // could not be dragged. An HStack with an explicit width and our own handle gives both
        // properties — the same structure agterm settled on, for the same reason.
        HStack(spacing: 0) {
            ClusterSidebar(store: store, actions: actions)
                .frame(width: store.sidebarWidth)
            // Above the detail pane: as the middle child it is drawn first, and the detail column
            // would otherwise shadow the right half of the grab strip.
            SidebarResizeHandle(actions: actions).zIndex(1)
            VSplitView {
                detail(store: store, actions: actions).frame(minHeight: 200)
                // The deck is omitted rather than collapsed: a zero-height split child still reserves
                // its divider, and an empty placeholder is not worth a sixth of a fresh window.
                if hasSessions(store) {
                    ExecSessionDeck(store: store, actions: actions).frame(minHeight: 160)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 600)
        .sheet(isPresented: Binding(get: { store.showingSettings }, set: { actions.setShowingSettings($0) })) {
            AuthSettingsView(store: store, actions: actions)
        }
        .sheet(item: Binding(get: { store.containerPicker }, set: { value in
            if value == nil, let picker = store.containerPicker { actions.cancelPodShell(selectionID: picker.id) }
        })) { picker in
            ContainerPicker(presentation: picker, actions: actions)
        }
        .task {
            if !store.hasLoadedConfiguration { await actions.loadConfiguration() }
            #if DEBUG
            if let fixture = composition.podValidation {
                await PodBrowsingValidation.run(fixture)
                return
            }
            if AWSVaultIsolationValidation.root != nil {
                await AWSVaultIsolationValidation.run(composition: composition)
            } else {
                await AuthLoginValidation.run(composition: composition)
                await ExecLiveValidation.run(composition: composition)
            }
            #endif
        }
    }

    private func hasSessions(_ store: AppStore) -> Bool {
        !store.logSessions.isEmpty || store.execSessions.contains { !$0.isClosed }
    }

    @ViewBuilder private func detail(store: AppStore, actions: AppActions) -> some View {
        if let selection = store.sidebarSelection,
           let cluster = store.clusters.first(where: { $0.id == selection.clusterName }) {
            if case .pods = selection, cluster.state == .connected {
                PodsPane(store: store, actions: actions)
            } else {
                ClusterPane(cluster: cluster, store: store, actions: actions)
            }
        } else {
            ContentUnavailableView("Select a cluster", systemImage: "server.rack")
        }
    }
}
