import KubixCore
import SwiftUI

struct NamespacePicker: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Namespace")
                TextField("Namespace", text: Binding(get: { store.namespaceDraft }, set: { actions.setNamespaceInput($0) }))
                    .onSubmit { actions.commitNamespaceInput() }
                    .accessibilityIdentifier("pod-namespace")
                Menu("Suggestions") {
                    ForEach(store.namespaces, id: \.self) { namespace in
                        Button(namespace) { try? actions.selectNamespace(namespace) }
                    }
                }.fixedSize()
                Button(store.connection == .idle ? "Load pods" : "Refresh pods") { actions.reloadSelectedPods() }
                    .disabled(store.selectedContext == nil)
                    .help("Commit this namespace and load pods")
            }
            Text("Browsing: \(store.selectedNamespace) · Type a known namespace and press Return, or choose a suggestion. No namespace-list permission needed.")
                .font(.caption).foregroundStyle(.secondary)
            if let diagnostic = store.namespaceDiagnostic { Text(diagnostic).foregroundStyle(.orange) }
        }
    }
}
