#if DEBUG
import AppKit
import KubixCore

@MainActor enum PodScaleNativeValidation {
    static func check(_ fixture: PodBrowsingFixture, table: NSTableView) async throws -> String {
        let actions = fixture.actions
        let store = fixture.store
        try actions.selectNamespace("scale")
        try await PodBrowsingValidation.until { await fixture.transport.scaleRequests == 2 }
        guard store.rows.isEmpty, table.numberOfRows == 0, store.connection == .connecting else { throw Failure.assertion }
        try await PodBrowsingValidation.until { store.connection == .live && table.numberOfRows == 1253 }
        try verify(fixture, table: table, ids: Set(0..<1253))
        guard await fixture.transport.scaleRequests == 5,
              await fixture.transport.scaleWatchVersions == ["scale-rv"] else { throw Failure.assertion }
        let add = try await event("ADDED", id: 1253, ids: Set(0...1253), fixture: fixture, table: table)
        let delete = try await event("DELETED", id: 0, ids: Set(1...1253), fixture: fixture, table: table)
        await fixture.transport.expireScaleWatch()
        try await PodBrowsingValidation.until {
            await fixture.transport.scaleWatchVersions.count == 2 && store.connection == .live && table.numberOfRows == 1253
        }
        try verify(fixture, table: table, ids: Set(0..<1253))
        guard await fixture.transport.scaleRequests == 8,
              await fixture.transport.scaleWatchVersions == ["scale-rv", "resync-rv"] else { throw Failure.assertion }
        return "CONTROLLED: 1253 exact UID/cell set, pages500/500/253; expired continuation discarded500 stale rows; "
            + "headerless/no-bookmark ADDED visible \(add)s, DELETED visible \(delete)s (each<2s); "
            + "410 watch relists full1253 with resync-rv; eight actual encoded page responses/attempts; no live mutation"
    }

    private static func event(
        _ type: String, id: Int, ids: Set<Int>, fixture: PodBrowsingFixture, table: NSTableView
    ) async throws -> String {
        let began = ContinuousClock.now
        try await fixture.transport.scaleEvent(type, id: id)
        try await PodBrowsingValidation.until {
            table.numberOfRows == ids.count && Set(fixture.store.rows.map(\.id)) == Set(ids.map { "scale-\($0)" })
                && cells(table) == Set(ids.map { "pod-\($0)" })
        }
        let elapsed = began.duration(to: .now)
        guard elapsed < .seconds(2) else { throw Failure.latency }
        try verify(fixture, table: table, ids: ids)
        let value = elapsed.components
        return String(format: "%.6f", Double(value.seconds) + Double(value.attoseconds) / 1e18)
    }

    private static func cells(_ table: NSTableView) -> Set<String> {
        Set((0..<table.numberOfRows).compactMap {
            (table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
        })
    }

    private static func verify(_ fixture: PodBrowsingFixture, table: NSTableView, ids: Set<Int>) throws {
        guard fixture.store.rows.count == ids.count, table.numberOfRows == ids.count,
              Set(fixture.store.rows.map(\.id)) == Set(ids.map { "scale-\($0)" }),
              cells(table) == Set(ids.map { "pod-\($0)" }), table.tableColumns.map(\.title) == ["Name"] else {
            throw Failure.assertion
        }
    }

    private enum Failure: Error { case assertion, latency }
}
#endif
