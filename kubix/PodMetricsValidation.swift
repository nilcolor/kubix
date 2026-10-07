#if DEBUG
import AppKit
import KubixCore

/// The columns the app computes: usage from the metrics API and an Age drawn from creation time.
/// Asserts they render through the real service and poll, that the Age is the computed one rather
/// than the server's frozen text and that it ticks, and that a changed sample reaches its cell with
/// the selection kept. Whether that redraw was per-cell or a full reload is not observable here: the
/// selection is re-applied either way, so that property rests on the coordinator's code alone.
@MainActor enum PodMetricsValidation {
    static func check(_ fixture: PodBrowsingFixture, table: NSTableView) async throws -> String {
        let store = fixture.store
        let actions = fixture.actions
        guard !store.listTable.columns.contains(where: { $0.kind == .cpu }) else { throw Failure.assertion }
        await fixture.metrics.serve(["alpha": ("250400000n", "131072Ki"), "zulu": ("0", "64Mi")])
        try actions.selectNamespace("timed")
        try await PodBrowsingValidation.until {
            store.connection == .live && table.tableColumns.map(\.title) == ["Name", "Status", "CPU", "Memory", "Age"]
        }
        try await PodBrowsingValidation.until { cell(table, pod: "alpha", column: "CPU") == "251m" }
        // The Name column was fitted to the longest name rather than left at a title-sized width.
        let longName = PodFixtureTransport.longName
        guard let name = table.tableColumns.first(where: { $0.title == "Name" }),
              let longRow = row(table, pod: longName),
              let label = (table.view(atColumn: table.column(withIdentifier: name.identifier), row: longRow, makeIfNecessary: true)
                as? NSTableCellView)?.textField,
              name.width > 110, label.intrinsicContentSize.width <= label.frame.width + 1 else { throw Failure.assertion }
        let nameWidth = Int(name.width)
        guard cell(table, pod: "alpha", column: "Memory") == "128Mi", cell(table, pod: "zulu", column: "CPU") == "0m",
              cell(table, pod: "zulu", column: "Memory") == "64Mi" else { throw Failure.assertion }

        // The server printed `1h` for a pod two hours old. kubectl prints minutes until three hours,
        // so the computed cell reads `120m` or a little more, depending on how long the run took.
        guard let age = cell(table, pod: "alpha", column: "Age"), age.hasSuffix("m"),
              let minutes = Int(age.dropLast()), (120..<180).contains(minutes) else { throw Failure.assertion }
        let before = cell(table, pod: "zulu", column: "Age")
        guard before != "5s", before?.hasSuffix("s") == true else { throw Failure.assertion }
        try await PodBrowsingValidation.until { cell(table, pod: "zulu", column: "Age") != before }

        guard let alpha = row(table, pod: "alpha") else { throw Failure.assertion }
        table.selectRowIndexes(IndexSet(integer: alpha), byExtendingSelection: false)
        try await PodBrowsingValidation.until { store.selectedRowUID == "uid-a" }
        await fixture.metrics.serve(["alpha": ("1500000000n", "131072Ki"), "zulu": ("0", "64Mi")])
        try await PodBrowsingValidation.until { cell(table, pod: "alpha", column: "CPU") == "1500m" }
        guard store.selectedRowUID == "uid-a", table.selectedRow == row(table, pod: "alpha") else { throw Failure.assertion }

        actions.sortList(.init(column: ResourceTablePresentation.Column.cpu.id, ascending: false))
        try await PodBrowsingValidation.until { row(table, pod: "alpha") == 0 }
        guard table.selectedRow == 0 else { throw Failure.assertion }
        return "Name column fitted to a \(longName.count)-character generated name (\(nameWidth)pt, untruncated); "
            + "real metrics service and poll render CPU/Memory before Age as kubectl top prints them; "
            + "Age computed from creation (\(age), not the printed 1h) and ticking; a new sample reaches "
            + "its cell with the selection kept; sorting by CPU moves the selected row with it"
    }

    private static func row(_ table: NSTableView, pod: String) -> Int? {
        guard let name = table.tableColumns.firstIndex(where: { $0.title == "Name" }) else { return nil }
        return (0..<table.numberOfRows).first { text(table, row: $0, column: name) == pod }
    }

    private static func cell(_ table: NSTableView, pod: String, column title: String) -> String? {
        guard let row = row(table, pod: pod), let column = table.tableColumns.firstIndex(where: { $0.title == title }) else {
            return nil
        }
        return text(table, row: row, column: column)
    }

    private static func text(_ table: NSTableView, row: Int, column: Int) -> String? {
        (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
    }

    private enum Failure: Error { case assertion }
}
#endif
