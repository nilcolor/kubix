import Foundation
import KubixCore
import Testing

struct WatchStateTests {
    @Test func orderedUIDCacheUpsertsDeletesAndRecreatesWithoutBookmarks() throws {
        var state = try watchState()
        #expect(state.receive(.added(try watchTable(rows: watchRow("two", rv: "add")))) == .applied)
        #expect(state.orderedUIDs == ["one", "two"])
        let modified = try watchTable(rows: watchRow("one", rv: "modify", cells: #"["updated"]"#))
        #expect(state.receive(.modified(modified)) == .applied)
        #expect(state.orderedUIDs == ["one", "two"] && state.rows[0].cells == [.string("updated")])
        #expect(state.receive(.deleted(try watchTable(rows: watchRow("one", rv: "delete")))) == .applied)
        #expect(state.rowsByUID["one"] == nil && state.orderedUIDs == ["two"])
        #expect(state.receive(.added(try watchTable(rows: watchRow("three", rv: "recreated")))) == .applied)
        #expect(state.rows.map(\.metadata.name) == ["same-name", "same-name"])
        #expect(state.orderedUIDs == ["two", "three"])
        #expect(state.end(.eof, elapsed: 300) == .watch(resourceVersion: "recreated"))
        #expect(state.rows.count == 2)
    }

    @Test func repeatedAddsUnknownModificationsAndDeletesAreUIDIdempotent() throws {
        var state = try watchState()
        let table = try watchTable()
        #expect(state.receive(.added(table)) == .applied)
        #expect(state.receive(.added(table)) == .applied && state.rows.count == 1)
        #expect(state.receive(.modified(try watchTable(rows: watchRow("unknown")))) == .applied)
        #expect(state.orderedUIDs == ["one", "unknown"])
        let delete = try watchTable(rows: watchRow("unknown", rv: "latest"))
        #expect(state.receive(.deleted(delete)) == .applied)
        #expect(state.receive(.deleted(delete)) == .applied)
        #expect(state.orderedUIDs == ["one"] && state.resourceVersion == "latest")
    }

    @Test func opaqueRVAlwaysAdvancesInStreamOrderEvenIfItLooksOlder() throws {
        var state = try watchState()
        for version in ["999", "2", "not-a-number", "α /+= opaque", "0001"] {
            #expect(state.receive(.modified(try watchTable(rv: version))) == .applied)
            #expect(state.resourceVersion == version)
            #expect(state.receive(.bookmark(try WatchBookmark(resourceVersion: "bookmark-" + version))) == .applied)
            #expect(state.resourceVersion == "bookmark-" + version)
        }
        #expect(state.receive(.modified(try watchTable(rv: "last-data"))) == .applied)
        #expect(state.end(.disconnected, elapsed: 10, jitter: 1) == .retry(delay: 1, resourceVersion: "last-data"))
        #expect(state.resume() == .watch(resourceVersion: "last-data"))
    }

    @Test(arguments: [nil, "null"])
    func missingAndNullSchemasPreservePreviousColumns(_ schema: String?) throws {
        var state = try watchState()
        let previous = state.columns
        #expect(state.receive(.modified(try watchTable(columns: schema))) == .applied)
        #expect(state.columns == previous)
    }

    @Test func explicitSchemasReplaceIncludingEmptyRatherThanReuse() throws {
        var state = try watchState()
        let replacement = #"[{"name":"New","type":"integer","priority":1}]"#
        #expect(state.receive(.modified(try watchTable(columns: replacement))) == .applied)
        #expect(state.columns?.map(\.name) == ["New"])
        #expect(state.receive(.modified(try watchTable(columns: "[]", rows: watchRow(cells: "[]")))) == .applied)
        #expect(state.columns == [] && state.rows[0].cells.isEmpty)
        var initial = try WatchState(rows: [], columns: nil, resourceVersion: "list")
        _ = initial.resume()
        #expect(initial.receive(.added(try watchTable(columns: watchColumns))) == .applied)
        #expect(initial.columns?.map(\.name) == ["Name"])
    }

    @Test func multirowEventsUseEnvelopeRVOrLastRowRVAndPreserveOrder() throws {
        var state = try watchState()
        let rows = watchRow("two", rv: "row-two") + "," + watchRow("three", rv: "row-three")
        #expect(state.receive(.added(try watchTable(rows: rows))) == .applied)
        #expect(state.orderedUIDs == ["one", "two", "three"] && state.resourceVersion == "row-three")
        #expect(state.receive(.modified(try watchTable(rv: "envelope", rows: rows))) == .applied)
        #expect(state.resourceVersion == "envelope")
        #expect(state.receive(.deleted(try watchTable(rv: "deleted", rows: rows))) == .applied)
        #expect(state.orderedUIDs == ["one"] && state.resourceVersion == "deleted")
    }

    @Test func bookmarkHeadersUpdateWithoutRowMutationAndValidateAtomically() throws {
        var state = try watchState()
        let rows = state.rows
        let table = watchTableJSON(rv: "bookmark-new", columns: #"[{"name":"Replacement","type":"string"}]"#, rows: "")
        let event = try JSONDecoder().decode(WatchEvent.self, from: watchLine("BOOKMARK", object: table))
        #expect(state.receive(event) == .applied)
        #expect(state.columns?.map(\.name) == ["Replacement"] && state.rows == rows)
        let columns = state.columns
        #expect(state.receive(.bookmark(try WatchBookmark(resourceVersion: "invalid", columnDefinitions: []))) == .failed(.decoding(.invalidPayload)))
        #expect(state.resourceVersion == "bookmark-new" && state.columns == columns && state.rows == rows)
    }

    @Test(arguments: ["MODIFIED", "DELETED"])
    func malformedMultirowUpdateAndDeleteDoNotPartiallyMutate(_ type: String) throws {
        var state = try watchState()
        let rows = state.rows
        let table = try watchTable(rows: watchRow("one", rv: "would-apply") + "," + watchRow("broken", cells: "[]"))
        let event = type == "MODIFIED" ? WatchEvent.modified(table) : .deleted(table)
        #expect(state.receive(event) == .failed(.decoding(.invalidPayload)))
        #expect(state.rows == rows && state.resourceVersion == "list-rv")
    }

    @Test(arguments: [
        "", #"{"cells":["bad"],"object":{"metadata":{"resourceVersion":"new"}}}"#,
        watchRow("", rv: "new"), watchRow("bad uid", rv: "new"), watchRow("two", rv: ""),
        watchRow("two") + "," + watchRow("two"),
        watchRow("two") + #",{"object":{"metadata":{"resourceVersion":"broken"}}}"#,
        watchRow("two") + "," + watchRow("three", cells: "[]"),
    ])
    func malformedPublicDataEventsAreAtomicIncludingValidPrefix(_ rows: String) throws {
        var state = try watchState()
        let oldRows = state.rows
        let columns = state.columns
        let event = WatchEvent.added(try watchTable(columns: #"[{"name":"Replacement","type":"string"}]"#, rows: rows))
        #expect(state.receive(event) == .failed(.decoding(.invalidPayload)))
        #expect(state.rows == oldRows && state.resourceVersion == "list-rv" && state.columns == columns)
        #expect(state.receive(try watchEvent("ADDED")) == .failed(.decoding(.invalidPayload)))
    }

    @Test func schemaMismatchWithUntouchedRowsDoesNotPartiallyApply() throws {
        var state = try watchState()
        let old = state.rows
        let columns = state.columns
        let table = try watchTable(columns: "[]", rows: watchRow("two", cells: "[]"))
        #expect(state.receive(.added(table)) == .failed(.decoding(.invalidPayload)))
        #expect(state.rows == old && state.columns == columns && state.resourceVersion == "list-rv")
    }

    @Test(arguments: [
        #"{"apiVersion":"v1","kind":"Pod","code":410}"#,
        #"{"apiVersion":"v1","kind":"Status","status":"Success","code":200}"#,
        #"{"apiVersion":"v1","kind":"Status","code":-1}"#, "{}",
    ])
    func publicErrorCaseCannotBypassDiscriminatorValidation(_ json: String) throws {
        var state = try watchState()
        let status = try JSONDecoder().decode(KubernetesStatus.self, from: Data(json.utf8))
        #expect(state.receive(.error(status)) == .failed(.decoding(.invalidPayload)))
        #expect(state.rows.count == 1 && state.resourceVersion == "list-rv")
    }

    @Test func snapshotValidationAndInvalidTransitionsAreExplicit() throws {
        let table = try watchTable(columns: watchColumns)
        let row = try PodRow(row: #require(table.rows.first))
        #expect(throws: WatchDecodingError.invalidPayload) {
            try WatchState(rows: [row, row], columns: nil, resourceVersion: "list")
        }
        #expect(throws: WatchDecodingError.invalidPayload) {
            try WatchState(rows: [row], columns: [], resourceVersion: "list")
        }
        #expect(throws: WatchDecodingError.invalidPayload) {
            try WatchState(rows: [], columns: nil, resourceVersion: "")
        }
        var ready = try WatchState(rows: [], columns: nil, resourceVersion: "list")
        #expect(ready.receive(.added(table)) == .failed(.invalidTransition))
        var active = try watchState()
        #expect(active.resume() == .failed(.invalidTransition))
    }

    @Test func framingFailureStopsStateAfterApplyingOnlyValidPrefix() throws {
        var state = try watchState()
        var decoder = WatchEventDecoder()
        let bytes = try watchLine("MODIFIED", object: watchTableJSON(rv: "applied"))
        let results = decoder.append(bytes + Data("{bad\n".utf8) + bytes)
        for result in results {
            switch result {
            case .success(let event): #expect(state.receive(event) == .applied)
            case .failure(let error): #expect(state.decodingFailed(error) == .failed(.decoding(.malformedEvent)))
            }
        }
        #expect(state.resourceVersion == "applied" && state.rows.count == 1)
        #expect(state.end(.eof, elapsed: 300) == .failed(.decoding(.malformedEvent)))
    }
}
