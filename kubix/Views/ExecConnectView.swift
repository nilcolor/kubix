import KubixCore
import SwiftUI

struct ExecConnectView: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Context", selection: Binding(
                    get: { store.selectedContext?.name ?? "" },
                    set: { try? actions.selectContext(named: $0) }
                )) {
                    if store.selectedContext == nil { Text("Select a context").tag("") }
                    ForEach(store.contexts, id: \.name) { Text($0.name).tag($0.name) }
                }
                Button("Reload kubeconfig") { Task { await actions.loadConfiguration() } }
                    .disabled(store.isLoadingConfiguration)
            }
            ForEach(Array(store.configurationDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Text(diagnostic).foregroundStyle(.orange).textSelection(.enabled)
            }
            if store.selectedContext?.cluster.insecureSkipTLSVerify == true {
                Text("WARNING: TLS certificate verification is disabled for this context.").foregroundStyle(.red)
            }
            HStack {
                TextField("Namespace", text: Binding(get: { store.selectedNamespace }, set: { actions.setNamespaceInput($0) }))
                TextField("Pod", text: Binding(get: { store.podName }, set: { actions.setPodName($0) }))
                TextField("Regular container", text: Binding(get: { store.containerName }, set: { actions.setContainerName($0) }))
                Button("Open shell") { actions.connectShell() }
                    .disabled(store.selectedContext == nil || store.podName.isEmpty || store.containerName.isEmpty)
            }
            Text("Temporary milestone form: explicitly choose a known running regular container. No namespace/pod discovery or resource mutation.")
                .font(.caption).foregroundStyle(.secondary)
            if let diagnostic = store.connectDiagnostic { Text(diagnostic).foregroundStyle(.orange) }
            AuthProgressView(store: store, actions: actions)
        }
        .padding()
    }
}
