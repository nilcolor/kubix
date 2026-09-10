import KubixCore
import SwiftUI

struct ContextPicker: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Context", selection: Binding(
                    get: { store.selectedContext?.name ?? "" },
                    set: { try? actions.selectContext(named: $0) }
                )) {
                    if store.selectedContext == nil { Text("Select a context").tag("") }
                    ForEach(store.contexts, id: \.name) { Text($0.name).tag($0.name) }
                }
                .accessibilityIdentifier("pod-context")
                Button("Reload kubeconfig") { Task { await actions.loadConfiguration() } }
                    .disabled(store.isLoadingConfiguration)
            }
            ForEach(Array(store.configurationDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Text(diagnostic).foregroundStyle(.orange).textSelection(.enabled)
            }
            if store.selectedContext?.cluster.insecureSkipTLSVerify == true {
                Text("WARNING: TLS certificate verification is disabled for this context.").foregroundStyle(.red)
            }
        }
    }
}
