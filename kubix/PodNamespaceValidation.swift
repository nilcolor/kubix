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
        // Every namespace the cluster listed and nothing else: the list is complete by construction.
        guard menu.itemTitles == ["empty", "known", "other", "team"] else { throw Failure.assertion }
        // There is no programmatic pop-up, and a real one runs a nested tracking loop that would stall
        // this driver, so the hook is exercised through the notification AppKit posts for it.
        for _ in 0..<3 {
            NotificationCenter.default.post(name: NSPopUpButton.willPopUpNotification, object: menu)
            try await Task.sleep(for: .milliseconds(20))
        }
        guard await fixture.transport.namespaceRequests == listed else { throw Failure.assertion }
        let geometry = try placement(of: menu, in: window)
        throttle = "native pop-up holds exactly the cluster's four listed namespaces; three "
            + "will-pop-up notifications inside the 30s window add no request; " + geometry

        await fixture.transport.failNamespaceList(.http(code: 403, resource: "namespaces"))
        fixture.actions.connect(contextNamed: "synthetic-second")
        try await PodBrowsingValidation.until { store.clusters[1].namespaces == .unavailable }
        guard store.clusters[1].state == .connected, store.authenticationDiagnostic == nil,
              store.namespaceDiagnostic == nil else { throw Failure.assertion }
        let denied = await fixture.transport.namespaceRequests
        fixture.actions.selectSidebar(.list("synthetic-second", .pods))
        try await PodBrowsingValidation.until { store.connection == .live }
        guard store.namespaces == ["other"], await fixture.transport.namespaceRequests == denied else {
            throw Failure.assertion
        }
        guard let fallbackField = control(in: window) as? NSComboBox else { throw Failure.assertion }
        NotificationCenter.default.post(name: NSComboBox.willPopUpNotification, object: fallbackField)
        try await Task.sleep(for: .milliseconds(30))
        guard await fixture.transport.namespaceRequests == denied else { throw Failure.assertion }
        try await typed(fixture, window: window)
        fallback = "a 403 list leaves the cluster connected with no diagnostic, a typeable field "
            + "instead of a pop-up, and no further namespace request from any path; typing does not "
            + "commit, Return commits once, an invalid draft is rejected and keeps the last namespace"
        await fixture.transport.failNamespaceList(nil)
        fixture.actions.selectSidebar(.list("synthetic-first", .pods))
        try await PodBrowsingValidation.until { store.connection == .live && store.selectedNamespace == "team" }
        // A listed cluster shows the server's namespaces, not the names typed into another cluster.
        guard store.namespaces == ["empty", "known", "other", "team"] else { throw Failure.assertion }
        return ["namespaceThrottle": throttle, "namespaceFallback": fallback]
    }

    /// Drafting and committing a name by hand, which only a cluster that denied the list offers.
    private static func typed(_ fixture: PodBrowsingFixture, window: NSWindow) async throws {
        let store = fixture.store
        let count = await fixture.transport.requests.count
        try await PodBrowsingValidation.edit("known", placeholder: "Namespace", in: window)
        try await PodBrowsingValidation.until { store.namespaceDraft == "known" }
        guard store.selectedNamespace == "other",
              await fixture.transport.requests.count == count else { throw Failure.assertion }
        try PodBrowsingValidation.submit(placeholder: "Namespace", in: window)
        try await PodBrowsingValidation.until { store.connection == .live && store.selectedNamespace == "known" }
        try await PodBrowsingValidation.edit("bad/input", placeholder: "Namespace", in: window)
        try PodBrowsingValidation.submit(placeholder: "Namespace", in: window)
        try await PodBrowsingValidation.until { store.namespaceDiagnostic != nil }
        guard store.selectedNamespace == "known", control(in: window) is NSComboBox else {
            throw Failure.assertion
        }
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
