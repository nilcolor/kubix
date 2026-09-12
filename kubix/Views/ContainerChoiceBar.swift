import KubixCore
import SwiftUI

/// The container choice lives above the table rather than in a sheet: it is a one-control decision,
/// there is room for it, and a modal hides the very pod list the choice is about.
struct ContainerChoiceBar: View {
    let presentation: ContainerPickerPresentation
    let actions: AppActions
    @State private var selected: String

    init(presentation: ContainerPickerPresentation, actions: AppActions) {
        self.presentation = presentation
        self.actions = actions
        _selected = State(initialValue: presentation.defaultContainer)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("Shell in \(presentation.pod)").fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
            Picker("Container", selection: $selected) {
                ForEach(presentation.containers, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .accessibilityIdentifier("container-choice")
            Button("Open shell") { actions.confirmPodShell(selectionID: presentation.id, container: selected) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel") { actions.cancelPodShell(selectionID: presentation.id) }
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        // A new selection must not inherit the previous pod's container.
        .id(presentation.id)
    }
}
