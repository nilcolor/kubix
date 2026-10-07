#if DEBUG
import AppKit
import KubixCore

/// The second kind in the same pane. Asserts the deployments list is driven by the server's own
/// deployment schema rather than the pod one renamed, that the pod-only affordances are absent
/// rather than merely disabled — no shell button, no Shell in the row menu, no usage columns on a
/// cluster that is already serving metrics — and that the Age the app computes replaces the printed
/// one here too.
@MainActor enum DeploymentListValidation {
    static func check(_ fixture: PodBrowsingFixture, window: NSWindow, table: NSTableView) async throws -> String {
        let store = fixture.store
        // The metrics stage ran before this one, so usage is available cluster-wide: the columns are
        // absent because the kind cannot have them, not because nothing has been sampled yet.
        guard store.clusters.first(where: { $0.context == store.selectedContext })?.metrics == .available,
              store.listTable.columns.contains(where: { $0.kind == .cpu }) else { throw Failure.assertion }

        fixture.actions.selectSidebar(.list("synthetic-second", .deployments))
        try await PodBrowsingValidation.until { store.connection == .live && store.listKind == .deployments }
        try await PodBrowsingValidation.until {
            table.tableColumns.map(\.title) == ["Name", "Ready", "Up-to-date", "Available", "Age"]
        }
        guard table.numberOfRows == 3, !store.listTable.columns.contains(where: { $0.kind == .cpu || $0.kind == .memory }),
              cell(table, name: "ledger", column: "Ready") == "1/3" else { throw Failure.assertion }

        // The server printed `6d` for a deployment two hours old; kubectl prints minutes until three
        // hours, so the computed cell reads `120m` or a little more depending on the run's length.
        guard let age = cell(table, name: PodFixtureTransport.deploymentRows[0].name, column: "Age"),
              age.hasSuffix("m"), let minutes = Int(age.dropLast()), (120..<180).contains(minutes),
              cell(table, name: "ledger", column: "Age")?.hasSuffix("s") == true else { throw Failure.assertion }

        // The row menu is real AppKit, so absence is observable there: a deployment row offers
        // neither action yet, where a pod row offers both. The pane's own buttons are SwiftUI and
        // are not addressable from the view hierarchy at all — `.help` sets no NSView tooltip and
        // `accessibilityIdentifier` is not bridged — so what the pane renders is asserted by the
        // `ResourceKind` flags it reads, in `DeploymentActionTests`.
        guard try rowMenu(name: "ledger", window: window, table: table).isEmpty else { throw Failure.assertion }

        // Wide reaches the deployment schema's own priority column, and search reads its cells.
        fixture.actions.setListWide(true)
        try await PodBrowsingValidation.until { table.tableColumns.map(\.title).contains("Selector") }
        fixture.actions.setListWide(false)
        fixture.actions.setListFilter("ledger")
        try await PodBrowsingValidation.until { table.numberOfRows == 1 }
        fixture.actions.setListFilter("")
        try await PodBrowsingValidation.until { table.numberOfRows == 3 }

        // Back to pods, which must restore the pod schema and its usage columns rather than leave
        // the deployment columns behind.
        fixture.actions.selectSidebar(.list("synthetic-second", .pods))
        try await PodBrowsingValidation.until {
            store.listKind == .pods && table.tableColumns.map(\.title).contains("CPU")
        }
        return "deployments list through the real WatchService against apps/v1 with the printer's own "
            + "columns (\(table.numberOfRows == 3 ? 3 : table.numberOfRows) rows, Ready 1/3 rendered); no CPU/Memory column on a cluster already "
            + "serving metrics; Age computed from creation (\(age), not the printed 6d); the native row "
            + "menu offers neither pod action; Wide reaches the deployment Selector column and search filters "
            + "its cells; switching back to Pods restores the pod schema and its usage columns"
    }

    /// Nil is the real no-menu answer, not a failure to build one: with neither action available the
    /// table returns no menu at all, which is what a right-click on a deployment row must produce.
    private static func rowMenu(name: String, window: NSWindow, table: NSTableView) throws -> [String] {
        guard let row = row(table, name: name) else { throw Failure.assertion }
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { throw Failure.assertion }
        return table.menu(for: event)?.items.map(\.title) ?? []
    }

    private static func row(_ table: NSTableView, name: String) -> Int? {
        guard let column = table.tableColumns.firstIndex(where: { $0.title == "Name" }) else { return nil }
        return (0..<table.numberOfRows).first { text(table, row: $0, column: column) == name }
    }

    private static func cell(_ table: NSTableView, name: String, column title: String) -> String? {
        guard let row = row(table, name: name),
              let column = table.tableColumns.firstIndex(where: { $0.title == title }) else { return nil }
        return text(table, row: row, column: column)
    }

    private static func text(_ table: NSTableView, row: Int, column: Int) -> String? {
        (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
    }

    private enum Failure: Error { case assertion }
}
#endif
