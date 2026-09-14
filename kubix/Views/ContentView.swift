import KubixCore
import SwiftUI

struct ContentView: View {
    let composition: AppComposition
    var body: some View {
        let store = composition.store
        let actions = composition.actions
        // The system split view, for the sidebar material, the collapse-past-minimum behaviour and
        // the toolbar's sidebar toggle. The detail column claims the width explicitly: without that
        // the split view hands its slack to the sidebar, which is what made the column track the
        // window the first time round.
        NavigationSplitView {
            ClusterSidebar(store: store, actions: actions)
                .navigationSplitViewColumnWidth(min: 180, ideal: 260, max: 360)
        } detail: {
            GeometryReader { proxy in
                let open = hasSessions(store)
                // Collapsed keeps every session running and gives the table the space back, so the
                // deck's height is the bar's alone rather than a fraction of the pane.
                let deck = open ? (store.deckCollapsed ? 37 : (proxy.size.height * store.deckFraction).rounded()) : 0
                VStack(spacing: 0) {
                    // One instance, height-adjusted: branching on the session count would give the
                    // pods pane a different identity with and without a deck, so opening the first
                    // shell would rebuild the table and drop its selection.
                    detail(store: store, actions: actions)
                        .frame(height: max(120, proxy.size.height - deck))
                    if open {
                        if store.deckCollapsed {
                            Divider()
                            CollapsedDeckBar(store: store, actions: actions).frame(height: deck)
                        } else {
                            DeckResizeHandle(
                                actions: actions, top: proxy.frame(in: .global).minY, total: proxy.size.height
                            )
                            ExecSessionDeck(store: store, actions: actions).frame(height: deck)
                        }
                    }
                }
            }
            // A real minimum, not just "any width": the split view reads an unbounded maximum as no
            // demand at all and grows the sidebar to its own maximum instead.
            .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 600)
        .sheet(isPresented: Binding(get: { store.showingSettings }, set: { actions.setShowingSettings($0) })) {
            AuthSettingsView(store: store, actions: actions)
        }
        .task {
            if !store.hasLoadedConfiguration { await actions.loadConfiguration() }
            #if DEBUG
            if let fixture = composition.podValidation {
                if PodUIPreview.isEnabled {
                    await PodUIPreview.run(fixture)
                } else {
                    await PodBrowsingValidation.run(fixture)
                }
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
