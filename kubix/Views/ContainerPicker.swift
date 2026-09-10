import KubixCore
import SwiftUI

struct ContainerPicker: View {
    let presentation: ContainerPickerPresentation
    let actions: AppActions
    @State private var selected: String

    init(presentation: ContainerPickerPresentation, actions: AppActions) {
        self.presentation = presentation
        self.actions = actions
        _selected = State(initialValue: presentation.defaultContainer)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shell in \(presentation.pod)").font(.headline)
            Text("Choose a running regular container.").foregroundStyle(.secondary)
            Picker("Container", selection: $selected) {
                ForEach(presentation.containers, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Button("Cancel") { actions.cancelPodShell(selectionID: presentation.id) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open shell") { actions.confirmPodShell(selectionID: presentation.id, container: selected) }
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(minWidth: 360)
    }
}
