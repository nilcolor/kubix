import AppKit
import KubixCore
import SwiftUI

/// A pop-up button when the cluster told us its namespaces, a text field when it did not.
///
/// A `Picker` with `.menu` is the native control for choosing one of a known set, and it is what the
/// design asks for — but it cannot express a namespace the app was never told about, and a cluster
/// that denies `list namespaces` is a supported configuration rather than an error. So the menu also
/// carries an "Other namespace…" item, and without a list the control falls back to typing.
struct NamespaceControl: View {
    let store: AppStore
    let actions: AppActions
    @State private var typing = false

    var body: some View {
        if let names = listed, !typing {
            NamespaceMenu(store: store, actions: actions, names: names) { typing = true }
        } else {
            NamespaceField(store: store, actions: actions, listed: listed != nil) { typing = false }
        }
    }

    private var listed: [String]? {
        guard case .listed = focusedDiscovery else { return nil }
        return store.namespaces.isEmpty ? nil : store.namespaces
    }

    private var focusedDiscovery: NamespaceDiscovery {
        store.selectedContext.flatMap { context in
            store.clusters.first { $0.context == context }?.namespaces
        } ?? .unknown
    }

}

/// `NSComboBox` rather than a plain field: it keeps the local history reachable while still accepting
/// a name the cluster never listed. Placeholder and identifier are stable because the native check
/// finds this control by them.
private struct NamespaceField: NSViewRepresentable {
    let store: AppStore
    let actions: AppActions
    let listed: Bool
    let done: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions, done: done) }

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
        context.coordinator.done = done
        if box.stringValue != store.namespaceDraft { box.stringValue = store.namespaceDraft }
        let items = store.namespaces
        if (box.objectValues as? [String]) != items {
            box.removeAllItems()
            box.addItems(withObjectValues: items)
        }
    }

    @MainActor final class Coordinator: NSObject, NSComboBoxDelegate {
        var actions: AppActions
        var done: () -> Void

        init(actions: AppActions, done: @escaping () -> Void) {
            self.actions = actions
            self.done = done
        }

        @objc func commit(_ sender: NSComboBox) {
            actions.setNamespaceInput(sender.stringValue)
            if actions.commitNamespaceInput() { done() }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            actions.setNamespaceInput(box.stringValue)
        }

        /// The list is fetched when the picker is about to open rather than polled, so it is current
        /// when it is read. The fetch is asynchronous, so a server-side change lands on the next open.
        func comboBoxWillPopUp(_ notification: Notification) {
            actions.refreshNamespaces()
        }

        /// Picking from the list is an explicit choice, so it commits without a second Return.
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox,
                  let value = box.objectValueOfSelectedItem as? String else { return }
            actions.setNamespaceInput(value)
            if actions.commitNamespaceInput() { done() }
        }
    }
}

/// A real `NSPopUpButton` rather than a SwiftUI `Picker`: the picker gives no hook for the menu being
/// about to open, and that hook is what refreshes the list exactly when it is read.
private struct NamespaceMenu: NSViewRepresentable {
    let store: AppStore
    let actions: AppActions
    let names: [String]
    let other: () -> Void

    static let otherTitle = "Other namespace…"

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions, other: other) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.identifier = NSUserInterfaceItemIdentifier("pod-namespace-menu")
        button.setAccessibilityIdentifier("pod-namespace-menu")
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        context.coordinator.observe(button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.other = other
        var titles = names
        if !titles.contains(store.selectedNamespace) { titles.insert(store.selectedNamespace, at: 0) }
        titles.append(Self.otherTitle)
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if button.titleOfSelectedItem != store.selectedNamespace {
            button.selectItem(withTitle: store.selectedNamespace)
        }
    }

    @MainActor final class Coordinator: NSObject {
        var actions: AppActions
        var other: () -> Void

        init(actions: AppActions, other: @escaping () -> Void) {
            self.actions = actions
            self.other = other
        }

        func observe(_ button: NSPopUpButton) {
            NotificationCenter.default.addObserver(
                self, selector: #selector(willPopUp(_:)),
                name: NSPopUpButton.willPopUpNotification, object: button
            )
        }

        /// Read time, not poll time: the list is refreshed as the menu opens, throttled by the store.
        @objc func willPopUp(_ notification: Notification) { actions.refreshNamespaces() }

        @objc func choose(_ sender: NSPopUpButton) {
            guard let title = sender.titleOfSelectedItem else { return }
            if title == NamespaceMenu.otherTitle {
                other()
                return
            }
            actions.setNamespaceInput(title)
            actions.commitNamespaceInput()
        }
    }
}
