import AppKit
import KubixCore
import SwiftUI

/// A pop-up button when the cluster told us its namespaces, a text field when it did not.
///
/// Namespaces are cluster-scoped, so a cluster that answers `list namespaces` answers with all of
/// them and the menu is complete — there is nothing for an escape hatch to reach. A cluster that
/// denies the list is a supported configuration rather than an error, and that is the only case the
/// typeable field exists for.
struct NamespaceControl: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        if let names = listed {
            NamespaceMenu(store: store, actions: actions, names: names)
        } else {
            NamespaceField(store: store, actions: actions)
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

/// Wide enough for an ordinary namespace name, bounded so a long one cannot push the page's actions
/// off the header.
private enum NamespaceMetrics {
    /// The same size class as the round actions beside it, so the control row shares one height.
    /// AppKit only gained the SwiftUI size the actions use in macOS 26; below that, one step down.
    static var controlSize: NSControl.ControlSize {
        if #available(macOS 26.0, *) { .extraLarge } else { .large }
    }

    static func size(fitting: CGSize) -> CGSize {
        CGSize(width: min(max(fitting.width, 150), 240), height: fitting.height)
    }
}

/// `NSComboBox` rather than a plain field: it keeps the local history reachable while still accepting
/// a name the cluster never listed. Placeholder and identifier are stable because the native check
/// finds this control by them.
private struct NamespaceField: NSViewRepresentable {
    let store: AppStore
    let actions: AppActions

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.placeholderString = "Namespace"
        box.identifier = NSUserInterfaceItemIdentifier("pod-namespace")
        box.setAccessibilityIdentifier("pod-namespace")
        box.completes = true
        box.controlSize = NamespaceMetrics.controlSize
        box.isButtonBordered = true
        box.numberOfVisibleItems = 12
        box.delegate = context.coordinator
        box.target = context.coordinator
        box.action = #selector(Coordinator.commit(_:))
        box.stringValue = store.namespaceDraft
        return box
    }

    /// Without this the representable accepts whatever width it is offered and the bezel is drawn
    /// against a frame the control never sized itself for.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSComboBox, context: Context) -> CGSize? {
        NamespaceMetrics.size(fitting: nsView.fittingSize)
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
            actions.commitNamespaceInput()
        }
    }
}

/// A real `NSPopUpButton` rather than a SwiftUI `Picker`: the picker gives no hook for the menu being
/// about to open, and that hook is what refreshes the list exactly when it is read.
private struct NamespaceMenu: NSViewRepresentable {
    let store: AppStore
    let actions: AppActions
    let names: [String]

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.identifier = NSUserInterfaceItemIdentifier("pod-namespace-menu")
        button.setAccessibilityIdentifier("pod-namespace-menu")
        button.controlSize = NamespaceMetrics.controlSize
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        context.coordinator.observe(button)
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        NamespaceMetrics.size(fitting: nsView.fittingSize)
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.actions = actions
        var titles = names
        if !titles.contains(store.selectedNamespace) { titles.insert(store.selectedNamespace, at: 0) }
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

        init(actions: AppActions) { self.actions = actions }

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
            actions.setNamespaceInput(title)
            actions.commitNamespaceInput()
        }
    }
}
