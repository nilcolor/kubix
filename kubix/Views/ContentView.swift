import KubixCore
import SwiftUI

struct ContentView: View {
    let composition: AppComposition
    var body: some View {
        let store = composition.store
        let actions = composition.actions
        NavigationSplitView {
            ClusterSidebar(store: store, actions: actions)
        } detail: {
            VSplitView {
                detail(store: store, actions: actions).frame(minHeight: 200)
                // The deck is omitted rather than collapsed: a zero-height split child still reserves
                // its divider, and an empty placeholder is not worth a sixth of a fresh window.
                if hasSessions(store) {
                    ExecSessionDeck(store: store, actions: actions).frame(minHeight: 160)
                }
            }
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
