#if DEBUG
import AppKit
import KubixCore

/// Namespace control stages: the native pop-up a listed cluster shows, its refresh throttle, and the
/// typeable field a denied listing falls back to. Returns the evidence keys the smoke report carries.
@MainActor enum PodNamespaceValidation {
    static func check(_ fixture: PodBrowsingFixture, window: NSWindow) async throws -> [String: String] {
        let store = fixture.store
        var throttle = ""
        var fallback = ""
        guard let menu = popUp(in: window) else { throw Failure.assertion }
        let listed = await fixture.transport.namespaceRequests
        guard menu.itemTitles == ["empty", "known", "other", "team", "Other namespace…"] else {
            throw Failure.assertion
        }
        // There is no programmatic pop-up, and a real one runs a nested tracking loop that would stall
        // this driver, so the hook is exercised through the notification AppKit posts for it.
        for _ in 0..<3 {
            NotificationCenter.default.post(name: NSPopUpButton.willPopUpNotification, object: menu)
            try await Task.sleep(for: .milliseconds(20))
        }
        guard await fixture.transport.namespaceRequests == listed else { throw Failure.assertion }
        let geometry = try placement(of: menu, in: window)
        throttle = "native pop-up holds the cluster's four listed namespaces plus "
            + "an Other item; three will-pop-up notifications inside the 30s window add no request; "
            + geometry

        await fixture.transport.failNamespaceList(.http(code: 403, resource: "namespaces"))
        fixture.actions.connect(contextNamed: "synthetic-second")
        try await PodBrowsingValidation.until { store.clusters[1].namespaces == .unavailable }
        guard store.clusters[1].state == .connected, store.authenticationDiagnostic == nil,
              store.namespaceDiagnostic == nil else { throw Failure.assertion }
        let denied = await fixture.transport.namespaceRequests
        fixture.actions.selectSidebar(.pods("synthetic-second"))
        try await PodBrowsingValidation.until { store.connection == .live }
        guard store.namespaces == ["other"], await fixture.transport.namespaceRequests == denied else {
            throw Failure.assertion
        }
        guard let fallbackField = control(in: window) as? NSComboBox else { throw Failure.assertion }
        NotificationCenter.default.post(name: NSComboBox.willPopUpNotification, object: fallbackField)
        try await Task.sleep(for: .milliseconds(30))
        guard await fixture.transport.namespaceRequests == denied else { throw Failure.assertion }
        fallback = "a 403 list leaves the cluster connected with no diagnostic, a "
            + "typeable field instead of a pop-up, and no further namespace request from any path"
        await fixture.transport.failNamespaceList(nil)
        fixture.actions.selectSidebar(.pods("synthetic-first"))
        try await PodBrowsingValidation.until { store.connection == .live && store.selectedNamespace == "team" }
        return ["namespaceThrottle": throttle, "namespaceFallback": fallback]
    }

    /// Reaches the typeable field whatever shape the control is in: a listed cluster shows a pop-up,
    /// and its Other item is the path a user takes for a namespace the cluster never listed.
    static func type(_ value: String, in window: NSWindow) async throws {
        if let menu = popUp(in: window) {
            menu.selectItem(withTitle: "Other namespace…")
            if let action = menu.action { NSApp.sendAction(action, to: menu.target, from: menu) }
            try await PodBrowsingValidation.until { control(in: window) is NSComboBox }
        }
        try await PodBrowsingValidation.edit(value, placeholder: "Namespace", in: window)
    }

    /// Either shape of the namespace control: a pop-up button when the cluster listed its namespaces,
    /// a combo box when it did not.
    static func control(in window: NSWindow) -> NSView? {
        PodBrowsingValidation.windowRoot(window).flatMap { root in
            descendants(root).first { $0.identifier?.rawValue == "pod-namespace-menu" }
                ?? descendants(root).compactMap { $0 as? NSTextField }
                    .first { $0.placeholderString == "Namespace" }
        }
    }

    static func popUp(in window: NSWindow) -> NSPopUpButton? {
        control(in: window) as? NSPopUpButton
    }

    /// The control used to sit in the toolbar's leading region, which spans the sidebar column, so it
    /// was drawn across the split divider. It belongs to the page, which means inside the content view
    /// rather than in the titlebar hierarchy the toolbar lays out.
    private static func placement(of control: NSView, in window: NSWindow) throws -> String {
        guard let content = window.contentView, descendants(content).contains(control) else {
            throw Failure.assertion
        }
        let size = control.frame.size
        guard size.width >= 150, size.width <= 240, size.height <= 40 else { throw Failure.assertion }
        return String(format: "sized %.0fx%.0f inside the page, not the toolbar", size.width, size.height)
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private enum Failure: Error { case assertion }
}
#endif
