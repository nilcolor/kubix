import AppKit
import KubixCore
import SwiftUI

/// A filterable picker when the cluster told us its namespaces, a text field when it did not.
///
/// Namespaces are cluster-scoped, so a cluster that answers `list namespaces` answers with all of
/// them and the list is complete — there is nothing for an escape hatch to reach. A cluster that
/// denies the list is a supported configuration rather than an error, and that is the only case the
/// typeable field exists for.
struct NamespaceControl: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        if let names = listed {
            // As tall as the round actions beside it; the row sizes itself to them.
            NamespacePicker(store: store, actions: actions, names: names)
                .frame(maxHeight: .infinity)
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

/// Looks and opens like a pop-up button, but the list it opens is a popover with a filter field: a
/// cluster can have hundreds of namespaces, and a menu only offers type-select on the first letters.
/// AppKit rather than SwiftUI because the opening is the hook that refreshes the list exactly when it
/// is read, and because the field editor's commands are what make the keyboard reliable.
private struct NamespacePicker: NSViewRepresentable {
    let store: AppStore
    let actions: AppActions
    let names: [String]

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: store.selectedNamespace, target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("pod-namespace-picker")
        button.setAccessibilityIdentifier("pod-namespace-picker")
        button.setAccessibilityRole(.popUpButton)
        // Not `.push`: that bezel is a fixed 24pt at every control size, half the height of the
        // round actions it sits beside.
        button.bezelStyle = .flexiblePush
        button.controlSize = NamespaceMetrics.controlSize
        button.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(scale: .small))
        button.imagePosition = .imageTrailing
        // Title at the leading edge and the chevron at the trailing one, as a pop-up button draws them.
        button.imageHugsTitle = false
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        context.coordinator.button = button
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        let fitting = NamespaceMetrics.size(fitting: nsView.fittingSize)
        guard let height = proposal.height, height.isFinite, height > fitting.height else { return fitting }
        return CGSize(width: fitting.width, height: height)
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.actions = actions
        if button.title != store.selectedNamespace { button.title = store.selectedNamespace }
        var items = names
        if !items.contains(store.selectedNamespace) { items.insert(store.selectedNamespace, at: 0) }
        context.coordinator.list.items = items
        context.coordinator.list.selected = [store.selectedNamespace]
    }

    @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
        var actions: AppActions
        private let popover = NSPopover()
        weak var button: NSButton?
        private var reopenSuppressedFor: Int?
        private(set) lazy var list = FilterListController(
            placeholder: "Filter namespaces", emptyText: "No matching namespaces", identifier: "namespace-picker-list",
            choose: { [weak self] name in self?.choose(name) },
            dismiss: { [weak self] in self?.popover.performClose(nil) }
        )

        init(actions: AppActions) {
            self.actions = actions
            super.init()
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
        }

        @objc func toggle(_ button: NSButton) {
            if let suppressed = reopenSuppressedFor {
                reopenSuppressedFor = nil
                if NSApp.currentEvent?.type == .leftMouseUp, NSApp.currentEvent?.eventNumber == suppressed { return }
            }
            guard !popover.isShown else { popover.performClose(nil); return }
            // Read time, not poll time: the list is refreshed as it opens, throttled by the store.
            actions.refreshNamespaces()
            popover.contentViewController = list
            list.prepareForOpening()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: button.isFlipped ? .maxY : .minY)
        }

        /// A transient popover closes on the mouse-down of a click on its own trigger, and that click's
        /// mouse-up then runs the trigger's action: without this the click meant to close the list
        /// reopens it.
        func popoverWillClose(_ notification: Notification) {
            guard let event = NSApp.currentEvent, event.type == .leftMouseDown, let button,
                  event.window === button.window,
                  button.bounds.contains(button.convert(event.locationInWindow, from: nil)) else { return }
            reopenSuppressedFor = event.eventNumber
        }

        private func choose(_ name: String) {
            popover.performClose(nil)
            actions.setNamespaceInput(name)
            actions.commitNamespaceInput()
        }
    }
}
