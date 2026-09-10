import KubixCore
import SwiftUI

struct ContentView: View {
    let composition: AppComposition
    var body: some View {
        let store = composition.store
        let actions = composition.actions
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ContextPicker(store: store, actions: actions)
                    NamespacePicker(store: store, actions: actions)
                    AuthProgressView(store: store, actions: actions)
                }.padding(12)
            }.frame(minHeight: 140, idealHeight: 210, maxHeight: 260)
            Divider()
            VSplitView {
                PodTableView(store: store, actions: actions).frame(minHeight: 140)
                ExecSessionDeck(store: store, actions: actions).frame(minHeight: 160)
            }.layoutPriority(1)
        }
        .frame(minWidth: 760, minHeight: 600)
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
}
