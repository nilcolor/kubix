import KubixCore
import SwiftUI

struct ContentView: View {
    let composition: AppComposition
    var body: some View {
        let store = composition.store
        let actions = composition.actions
        VStack(spacing: 0) {
            ExecConnectView(store: store, actions: actions)
            Divider()
            ExecSessionDeck(store: store, actions: actions)
        }
        .frame(minWidth: 760, minHeight: 600)
        .sheet(isPresented: Binding(get: { store.showingSettings }, set: { actions.setShowingSettings($0) })) {
            AuthSettingsView(store: store, actions: actions)
        }
        .task {
            if !store.hasLoadedConfiguration { await actions.loadConfiguration() }
            #if DEBUG
            if AWSVaultIsolationValidation.root != nil {
                await AWSVaultIsolationValidation.run(composition: composition)
            } else {
                await AuthLoginValidation.run(composition: composition)
                await ExecLiveValidation.run(composition: composition)
            }
            #endif
        }
    }
}
