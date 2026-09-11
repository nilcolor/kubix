import AppKit
import KubixCore
import SwiftUI

/// `NSComboBox` because the namespace has to be both pickable and typeable: the list is local history
/// plus the configured namespace, so it can be empty, and typing must keep working when it is.
struct NamespaceCombo: NSViewRepresentable {
    let store: AppStore
    let actions: AppActions

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.placeholderString = "Namespace"
        box.identifier = NSUserInterfaceItemIdentifier("pod-namespace")
        box.setAccessibilityIdentifier("pod-namespace")
        box.completes = true
        box.isButtonBordered = true
        box.numberOfVisibleItems = 12
        box.delegate = context.coordinator
        box.target = context.coordinator
        box.action = #selector(Coordinator.commit(_:))
        box.stringValue = store.namespaceDraft
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.actions = actions
        if box.stringValue != store.namespaceDraft { box.stringValue = store.namespaceDraft }
        let items = store.namespaces
        if (box.objectValues as? [String]) != items {
            box.removeAllItems()
            box.addItems(withObjectValues: items)
        }
    }

    @MainActor final class Coordinator: NSObject, NSComboBoxDelegate {
        var actions: AppActions

        init(actions: AppActions) { self.actions = actions }

        @objc func commit(_ sender: NSComboBox) {
            actions.setNamespaceInput(sender.stringValue)
            actions.commitNamespaceInput()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            actions.setNamespaceInput(box.stringValue)
        }

        /// Picking from the list is an explicit choice, so it commits without a second Return.
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox,
                  let value = box.objectValueOfSelectedItem as? String else { return }
            actions.setNamespaceInput(value)
            actions.commitNamespaceInput()
        }
    }
}
