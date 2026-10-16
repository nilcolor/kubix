#if DEBUG
import AppKit
import KubixCore

/// Namespace control stages: the filterable picker a listed cluster shows, its refresh throttle, and
/// the typeable field a denied listing falls back to. Returns the evidence keys the smoke report carries.
@MainActor enum PodNamespaceValidation {
    static func check(_ fixture: PodBrowsingFixture, window: NSWindow) async throws -> [String: String] {
        let store = fixture.store
        var throttle = ""
        var picked = ""
        var fallback = ""
        guard let picker = picker(in: window), picker.title == "team" else { throw Failure.assertion }
        let listed = await fixture.transport.namespaceRequests
        for _ in 0..<3 {
            // Every namespace the cluster listed and nothing else: the list is complete by construction.
            guard try await open(picker) == ["empty", "known", "other", "team"] else { throw Failure.assertion }
            try await close()
        }
        guard await fixture.transport.namespaceRequests == listed else { throw Failure.assertion }
        let geometry = try placement(of: picker, in: window)
        throttle = "picker lists exactly the cluster's four listed namespaces; three openings inside "
            + "the 30s window add no request; " + geometry
        picked = try await filtered(fixture, picker: picker)

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
            + "instead of a picker, and no further namespace request from any path; typing does not "
            + "commit, Return commits once, an invalid draft is rejected and keeps the last namespace"
        await fixture.transport.failNamespaceList(nil)
        fixture.actions.selectSidebar(.list("synthetic-first", .pods))
        try await PodBrowsingValidation.until { store.connection == .live && store.selectedNamespace == "team" }
        // A listed cluster shows the server's namespaces, not the names typed into another cluster.
        guard store.namespaces == ["empty", "known", "other", "team"] else { throw Failure.assertion }
        return ["namespaceThrottle": throttle, "namespacePicker": picked, "namespaceFallback": fallback]
    }

    /// Typing narrows the list and Return commits the highlighted name, driven through the search
    /// field's own field editor; the second pass moves the highlight with the arrow keys instead.
    private static func filtered(_ fixture: PodBrowsingFixture, picker: NSButton) async throws -> String {
        let store = fixture.store
        _ = try await open(picker)
        guard let popover = listWindow() else { throw Failure.assertion }
        try await PodBrowsingValidation.edit("o", placeholder: Self.filter, in: popover)
        try await PodBrowsingValidation.until { (try? rows()) == ["other", "known"] }
        try await PodBrowsingValidation.edit("kn", placeholder: Self.filter, in: popover)
        try await PodBrowsingValidation.until { (try? rows()) == ["known"] }
        guard store.selectedNamespace == "team" else { throw Failure.assertion }
        try command("insertNewline:", in: popover)
        try await PodBrowsingValidation.until {
            store.connection == .live && store.selectedNamespace == "known" && listWindow() == nil
        }
        guard picker.title == "known" else { throw Failure.assertion }

        guard try await open(picker) == ["empty", "known", "other", "team"],
              let reopened = listWindow(), list()?.selectedRow == 1 else { throw Failure.assertion }
        try command("moveDown:", in: reopened)
        try command("moveDown:", in: reopened)
        try command("moveDown:", in: reopened)
        guard list()?.selectedRow == 3 else { throw Failure.assertion }
        try command("insertNewline:", in: reopened)
        try await PodBrowsingValidation.until {
            store.connection == .live && store.selectedNamespace == "team" && listWindow() == nil
        }
        return "\"o\" ranks other before known, \"kn\" leaves known and Return commits it; reopening "
            + "highlights the committed name, arrows stop at the last row and Return commits team"
    }

    private static let filter = "Filter namespaces"

    @discardableResult
    private static func open(_ picker: NSButton) async throws -> [String] {
        picker.performClick(nil)
        try await PodBrowsingValidation.until { listWindow() != nil && list() != nil }
        return try rows()
    }

    /// Escape on an empty filter is the keyboard's way out, so closing goes through it too.
    private static func close() async throws {
        guard let popover = listWindow() else { throw Failure.assertion }
        try command("cancelOperation:", in: popover)
        try await PodBrowsingValidation.until { listWindow() == nil }
    }

    private static func command(_ selector: String, in popover: NSWindow) throws {
        guard let field = PodBrowsingValidation.windowRoot(popover).flatMap({ root in
                  descendants(root).compactMap { $0 as? NSSearchField }.first { $0.placeholderString == filter }
              }),
              let editor = popover.fieldEditor(false, for: field) as? NSTextView else { throw Failure.assertion }
        editor.doCommand(by: NSSelectorFromString(selector))
    }

    private static func rows() throws -> [String] {
        guard let table = list() else { throw Failure.assertion }
        return (0..<table.numberOfRows).map { row in
            (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue ?? ""
        }
    }

    /// The popover is its own window, so its presence is what says the list is open.
    private static func listWindow() -> NSWindow? {
        NSApp.windows.first { $0.className.contains("Popover") && $0.isVisible }
    }

    private static func list() -> NSTableView? {
        listWindow().flatMap(PodBrowsingValidation.windowRoot).flatMap { root in
            descendants(root).compactMap { $0 as? NSTableView }.first { $0.identifier?.rawValue == "namespace-picker-list" }
        }
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

    /// Either shape of the namespace control: a picker when the cluster listed its namespaces, a combo
    /// box when it did not.
    static func control(in window: NSWindow) -> NSView? {
        PodBrowsingValidation.windowRoot(window).flatMap { root in
            descendants(root).first { $0.identifier?.rawValue == "pod-namespace-picker" }
                ?? descendants(root).compactMap { $0 as? NSTextField }
                    .first { $0.placeholderString == "Namespace" }
        }
    }

    static func picker(in window: NSWindow) -> NSButton? {
        control(in: window) as? NSButton
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
