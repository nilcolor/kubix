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
        // A namespace commit while a deployments list is selected re-lists deployments, not pods.
        try fixture.actions.selectNamespace("team")
        try await PodBrowsingValidation.until {
            store.connection == .live && store.listKind == .deployments && store.selectedNamespace == "team"
        }
        try await PodBrowsingValidation.until {
            table.tableColumns.map(\.title) == ["Name", "Ready", "Up-to-date", "Available", "Age"]
        }
        let rows = table.numberOfRows
        guard rows == 3, !store.listTable.columns.contains(where: { $0.kind == .cpu || $0.kind == .memory }),
              cell(table, name: "ledger", column: "Ready") == "1/3" else { throw Failure.assertion }

        // The server printed `6d` for a deployment two hours old; kubectl prints minutes until three
        // hours, so the computed cell reads `120m` or a little more depending on the run's length.
        guard let age = cell(table, name: PodFixtureTransport.deploymentRows[0].name, column: "Age"),
              age.hasSuffix("m"), let minutes = Int(age.dropLast()), (120..<180).contains(minutes),
              cell(table, name: "ledger", column: "Age")?.hasSuffix("s") == true else { throw Failure.assertion }

        // The row menu is real AppKit, so what a deployment row offers is observable there: Logs
        // alone, where a pod row offers Shell and Logs. The pane's own buttons are SwiftUI and are
        // not addressable from the view hierarchy at all — `.help` sets no NSView tooltip and
        // `accessibilityIdentifier` is not bridged — so what the pane renders is asserted by the
        // `ResourceKind` flags it reads, in `DeploymentActionTests`.
        guard try rowMenu(name: "ledger", window: window, table: table) == ["Logs"] else { throw Failure.assertion }
        let aggregated = try await logs(fixture, window: window, table: table)

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
        return aggregated + "; deployments list through the real WatchService against apps/v1 with the "
            + "printer's own columns (\(rows) rows, Ready 1/3 rendered); no CPU/Memory column on a cluster "
            + "already serving metrics; Age computed from creation (\(age), not the printed 6d); the native "
            + "row menu offers Logs alone, with no Shell; Wide reaches the deployment Selector column and "
            + "search filters its cells; switching back to Pods restores the pod schema and its usage columns"
    }

    /// Nil is the real no-menu answer, not a failure to build one: with neither action available the
    /// table returns no menu at all, which is what a right-click on a deployment row must produce.
    /// Aggregated logs, through the real DeploymentDetailsService, DeploymentPodService and
    /// LogService: one tab, one stream per pod the selector found, and every line labelled with the
    /// pod that logged it.
    private static func logs(
        _ fixture: PodBrowsingFixture, window: NSWindow, table: NSTableView
    ) async throws -> String {
        let store = fixture.store
        guard let row = store.listTable.rows.first(where: { $0.cells.first == "ledger" }) else {
            throw Failure.assertion
        }
        fixture.actions.openDeploymentLogs(uid: row.id)
        // Two template containers, so the flow asks which before it resolves any pods.
        try await PodBrowsingValidation.until { store.containerPicker != nil }
        guard let picker = store.containerPicker, picker.pod == "deploy/ledger",
              picker.containers == ["server", "proxy"], picker.defaultContainer == "server",
              picker.items.allSatisfy({ $0.state == nil }) else { throw Failure.assertion }
        fixture.actions.confirmDeploymentLogs(selectionID: picker.id, container: "server")

        let expected = PodFixtureTransport.deploymentPodNames.count
        try await PodBrowsingValidation.until { store.logSessions.last?.followingCount == expected }
        guard let session = store.logSessions.last else { throw Failure.assertion }
        // Every stream must have delivered, not just enough lines to pass a count: a line from one
        // chatty pod would satisfy that while two others sat idle.
        try await PodBrowsingValidation.until {
            Set(session.buffer.lines.compactMap(\.source)) == Set(PodFixtureTransport.deploymentPodNames)
        }
        let labelled = Set(session.buffer.lines.compactMap(\.source))
        // Newest pod first, which is the order a capped set would have kept.
        guard session.sources.count == expected, session.resolved == nil,
              session.sources.map(\.target.pod) == PodFixtureTransport.deploymentPodNames.reversed(),
              labelled == Set(PodFixtureTransport.deploymentPodNames),
              session.buffer.maximumLines > LogBuffer.baseLines,
              session.scope.subject == .deployment(name: "ledger", uid: "deploy-ledger"),
              fixture.actions.sessionTarget(.logs(session.id))?.display == "deploy/ledger"
        else { throw Failure.assertion }
        // The deck's count comes from the session, which is what is assertable here: SwiftUI's
        // static text is drawn rather than backed by an NSTextField, so the label itself is not in
        // the view hierarchy to find. What it renders is covered by `LogSessionStateTests`.
        guard let summary = session.followingSummary, summary == "\(expected)/\(expected) pods" else {
            throw Failure.assertion
        }

        // Read before Close, which drops the buffer: a figure captured after it would describe the
        // ring a closed tab was reset to.
        let evidence = "\(session.buffer.count) lines each labelled with the pod that logged it, "
            + "ring grown to \(session.buffer.maximumLines) lines"

        fixture.actions.closeLog(session.id)
        try await PodBrowsingValidation.until { store.logSessions.allSatisfy { $0.id != session.id } }
        return "aggregated deployment logs: one tab over \(expected) real pod streams found through the "
            + "deployment's own selector, newest pod first, " + evidence + ", tab titled deploy/ledger "
            + "with the deck reading \(summary); template containers offered with no state claimed"
    }

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
