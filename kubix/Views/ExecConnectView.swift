import KubixCore
import SwiftUI

struct ExecConnectView: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Pod", text: Binding(get: { store.podName }, set: { actions.setPodName($0) }))
                TextField("Regular container", text: Binding(get: { store.containerName }, set: { actions.setContainerName($0) }))
                Button("Open shell") { actions.connectShell() }
                    .disabled(store.selectedContext == nil || store.podName.isEmpty || store.containerName.isEmpty)
            }
            Text("Temporary explicit target: use the namespace above and a known running regular container. Table selection does not open a shell.")
                .font(.caption).foregroundStyle(.secondary)
            if let diagnostic = store.connectDiagnostic { Text(diagnostic).foregroundStyle(.orange) }
        }
    }
}
