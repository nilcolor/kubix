import KubixCore
import SwiftUI

struct AuthSettingsView: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        Form {
            Text("App-only authentication settings").font(.headline)
            Text("These settings never edit kubeconfig or AWS files. Login-shell PATH discovery is best effort; "
                 + "interactive mise/asdf setup may require a stable shim directory or absolute executable.")
                .font(.caption)
            Text("Additional absolute search directories (one per line)")
            TextEditor(text: draft(\.searchDirectories)).frame(height: 65).font(.system(.body, design: .monospaced))
            if let command = store.selectedContext?.user?.exec?.command {
                Text("Configured plugin: \(command)").textSelection(.enabled)
                TextField("Absolute executable override (optional)", text: draft(\.executableOverride))
                TextField("Already-configured AWS SSO profile (optional binding)", text: draft(\.profile))
                TextField("SSO session name (optional, already resolved)", text: draft(\.session))
                Text("Bindings apply to the selected kubeconfig user. Conflicting argument/environment profiles are rejected.")
                    .font(.caption)
            }
            if let diagnostic = store.settingsDiagnostic { Text(diagnostic).foregroundStyle(.secondary) }
            HStack {
                Button("Save") { Task { await actions.saveAuthSettings() } }
                Button("Done") { actions.setShowingSettings(false) }
            }
        }
        .padding()
        .frame(width: 580)
    }

    private func draft(_ keyPath: WritableKeyPath<AuthSettingsDraft, String>) -> Binding<String> {
        Binding(
            get: { store.settingsDraft[keyPath: keyPath] },
            set: { value in
                var draft = store.settingsDraft
                draft[keyPath: keyPath] = value
                actions.setSettingsDraft(draft)
            }
        )
    }
}
