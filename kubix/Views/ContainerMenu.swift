import KubixCore
import SwiftUI

/// The container choice, as a menu hanging off the button that asked for it. There is no confirm
/// step: the pod is already chosen and the container is the only remaining question, so choosing one
/// is the decision. What each container is for — the pod's nominated default, a sidecar, an init or
/// ephemeral container — is named beside it, because the names alone rarely say.
struct ContainerMenu: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        if let picker = store.containerPicker {
            VStack(alignment: .leading, spacing: 0) {
                Text(picker.purpose.title)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                ForEach(picker.items) { item in
                    Choice(item: item, isDefault: item.name == picker.defaultContainer) {
                        choose(picker, container: item.name)
                    }
                }
                Divider().padding(.top, 4)
                Text(picker.purpose.hint)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(width: 290)
            // The first choice takes key focus when the menu opens, and its ring reads as a state
            // the menu does not have: there is no keyboard traversal here to indicate.
            .focusEffectDisabled()
            .accessibilityIdentifier("container-menu")
        }
    }

    /// Logs reach two different confirmations: a pod's own stream, or every pod of a deployment.
    /// The list slot says which, because it is what the selected row came from.
    private func choose(_ picker: ContainerPickerPresentation, container: String) {
        switch picker.purpose {
        case .shell: actions.confirmPodShell(selectionID: picker.id, container: container)
        case .logs:
            if store.listKind == .deployments {
                actions.confirmDeploymentLogs(selectionID: picker.id, container: container)
            } else {
                actions.confirmPodLogs(selectionID: picker.id, container: container)
            }
        }
    }
}

private struct Choice: View {
    let item: ContainerPickerPresentation.Item
    let isDefault: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .opacity(isDefault ? 1 : 0)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).fontWeight(.medium)
                    Text(item.role).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                // A pod template's containers have no state to report, so nothing is drawn for them.
                if let state = item.state {
                    Text(state)
                        .font(.caption)
                        .foregroundStyle(state == "Running" ? Color.green : .secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.accentColor.opacity(0.14) : .clear).padding(.horizontal, 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("container-choice-\(item.name)")
    }
}
