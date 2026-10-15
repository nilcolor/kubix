import KubixCore
import SwiftUI

/// Names what it deletes and where. There is no default button: Return must not delete.
struct PodDeletionDialog: View {
    let deletion: PodDeletionPresentation
    let actions: AppActions
    @FocusState private var cancelFocused: Bool

    /// Enough names to recognise the selection as the one meant; past that the count speaks.
    private static let listedPods = 5

    private var many: Bool { deletion.pods.count > 1 }

    private var title: String {
        many ? "Delete \(deletion.pods.count) pods?" : "Delete “\(deletion.pods.first ?? "")”?"
    }

    private var message: String {
        let place = "\(deletion.namespace) on \(deletion.context)"
        return many
            ? "They will be removed from \(place), each stopping within its grace period. "
                + "Controllers may create replacements automatically."
            : "The pod will be removed from \(place), stopping within its grace period. "
                + "A controller may create a replacement automatically."
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.title3.weight(.semibold))
                    if many { names }
                    Text(message).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button("Cancel") { actions.cancelPodDeletion(id: deletion.id) }
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
                Button(many ? "Delete \(deletion.pods.count) Pods" : "Delete Pod", role: .destructive) {
                    actions.confirmPodDeletion(id: deletion.id)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 480)
        .defaultFocus($cancelFocused, true)
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Names are unique within the one namespace the dialog is about.
            ForEach(deletion.pods.prefix(Self.listedPods), id: \.self) { Text($0) }
            if deletion.pods.count > Self.listedPods {
                Text("and \(deletion.pods.count - Self.listedPods) more").foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }
}
