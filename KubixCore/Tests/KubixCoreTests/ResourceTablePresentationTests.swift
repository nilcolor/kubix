import Foundation
import KubixCore
import Testing

struct PodTablePresentationTests {
    @Test func serverOrderDuplicateNamesPrioritiesAndEveryCellFormat() throws {
        let table = try presentationTable(
            columns: """
            [{"name":"Custom","type":"string","description":"From server"},{"name":"Custom","type":"integer","priority":2},
             {"name":"Flag","type":"boolean","priority":-1},{"name":"Missing","type":"string"},
             {"name":"Nested","type":"future-type"},{"name":"Timestamp","type":"date","format":"date-time"}]
            """,
            cells: [#"["display",12.50,true,null,{"z":[1,false],"a":"b"},"2026-09-10T12:00:00Z"]"#]
        )
        let normal = try present(table)
        #expect(normal.columns.map(\.id) == [0, 2, 3, 4, 5])
        #expect(normal.columns.first?.definition.description == "From server")
        #expect(normal.rows.first?.cells == ["display", "true", "", #"{"a":"b","z":[1,false]}"#, "2026-09-10T12:00:00Z"])
        let wide = try present(table, wide: true)
        #expect(wide.columns.map(\.definition.name) == ["Custom", "Custom", "Flag", "Missing", "Nested", "Timestamp"])
        #expect(wide.rows.first?.cells[1] == "12.5")
    }

    @Test func numericBooleanNaturalAndStableSorts() throws {
        let table = try presentationTable(
            columns: #"[{"name":"Printed","type":"integer"},{"name":"Count","type":"number"},{"name":"Flag","type":"boolean"}]"#,
            cells: [#"["pod10",10,true]"#, #"["Pód2",2,false]"#, #"["pod2",2,true]"#, #"["pod3",null,false]"#]
        )
        #expect(try present(table, sort: .init(column: 0)).rows.map(\.id) == ["uid-1", "uid-2", "uid-3", "uid-0"])
        #expect(try present(table, sort: .init(column: 1)).rows.map(\.id) == ["uid-1", "uid-2", "uid-0", "uid-3"])
        #expect(try present(table, sort: .init(column: 1, ascending: false)).rows.map(\.id) == ["uid-0", "uid-1", "uid-2", "uid-3"])
        #expect(try present(table, sort: .init(column: 2)).rows.map(\.id) == ["uid-1", "uid-3", "uid-0", "uid-2"])
        #expect(try present(table, sort: .init(column: 99)).sort == nil)
    }

    @Test func filterOnlyVisibleCellsAndHiddenSortIsRemoved() throws {
        let table = try presentationTable(
            columns: #"[{"name":"Label","type":"string"},{"name":"Private-wide","type":"string","priority":1}]"#,
            cells: [#"["Café","node2"]"#, #"["alpha","node1"]"#]
        )
        #expect(try present(table, filter: " CAFE ").rows.map(\.id) == ["uid-0"])
        #expect(try present(table, filter: "node").state == .filteredEmpty)
        #expect(try present(table, filter: "node", wide: true).rows.count == 2)
        #expect(try present(table, sort: .init(column: 1)).sort == nil)
        #expect(try present(table, wide: true, sort: .init(column: 1)).rows.map(\.id) == ["uid-1", "uid-0"])
        #expect(try present(table, filter: " \n ").rows.count == 2)
    }

    @Test func heterogeneousValuesHaveTransitiveTypeOrderingWithNullAlwaysLast() throws {
        let table = try presentationTable(
            columns: #"[{"name":"Sometimes numeric","type":"number"}]"#,
            cells: [#"[-2]"#, #"["-3"]"#, #"[-10]"#, #"[null]"#, #"[false]"#, #"[[]]"#, #"[{}]"#, #"[-2.5]"#]
        )
        #expect(try present(table, sort: .init(column: 0)).rows.map(\.id) == [
            "uid-2", "uid-7", "uid-0", "uid-4", "uid-1", "uid-5", "uid-6", "uid-3",
        ])
        #expect(try present(table, sort: .init(column: 0, ascending: false)).rows.map(\.id) == [
            "uid-6", "uid-5", "uid-1", "uid-4", "uid-0", "uid-7", "uid-2", "uid-3",
        ])
    }

    @Test func selectionSurvivesReorderButNotFilteringDeletionOrSameNameReplacement() throws {
        let table = try presentationTable(cells: [#"["same"]"#, #"["another"]"#])
        let source = try table.rows.map(ResourceRow.init)
        let selected = ResourceTablePresentation(rows: source.reversed(), columns: table.columnDefinitions, connection: .live, selectedUIDs: ["uid-0"])
        #expect(selected.selectedUID == "uid-0")
        #expect(try present(table, filter: "another", selected: "uid-0").selectedUID == nil)
        let deleted = ResourceTablePresentation(rows: Array(source.dropFirst()), columns: table.columnDefinitions, connection: .live, selectedUIDs: ["uid-0"])
        #expect(deleted.selectedUID == nil)
        let replaced = try presentationTable(cells: [#"["same"]"#], uidPrefix: "replacement")
        #expect(try present(replaced, selected: "uid-0").selectedUID == nil)
    }

    @Test func aMultipleSelectionIsInDisplayOrderAndHasNoSingleRow() throws {
        let table = try presentationTable(cells: [#"["b"]"#, #"["a"]"#, #"["c"]"#])
        let rows = try table.rows.map(ResourceRow.init)
        let sorted = ResourceTablePresentation(
            rows: rows, columns: table.columnDefinitions, connection: .live,
            sort: .init(column: 0, ascending: true), selectedUIDs: ["uid-0", "uid-1", "absent"]
        )
        #expect(sorted.selectedUIDs == ["uid-1", "uid-0"] && sorted.selectedUID == nil)
        let filtered = ResourceTablePresentation(
            rows: rows, columns: table.columnDefinitions, connection: .live, filter: "a", selectedUIDs: ["uid-0", "uid-1"]
        )
        #expect(filtered.selectedUIDs == ["uid-1"] && filtered.selectedUID == "uid-1")
    }

    @Test func emptyIdleConnectingFailedAndLiveAreDistinctAndStaleRowsAreExplicit() throws {
        let empty = try presentationTable(cells: [])
        #expect(try present(empty).state == .empty)
        let table = try presentationTable(cells: [#"["alpha"]"#])
        let rows = try table.rows.map(ResourceRow.init)
        let cases: [(ListConnection, ResourceTablePresentation.State)] = [
            (.idle, .idle), (.connecting, .connecting), (.failed(.podAuthentication), .failed), (.live, .live),
        ]
        for (connection, state) in cases {
            let value = ResourceTablePresentation(rows: rows, columns: table.columnDefinitions, connection: connection)
            #expect(value.state == state)
            if state == .failed || state == .connecting { #expect(value.message.contains("not live")) }
        }
        let connecting = ResourceTablePresentation(rows: [], columns: nil, connection: .connecting)
        #expect(connecting.state == .connecting && connecting.message.contains("complete"))
        #expect(ResourceTablePresentation(rows: [], columns: nil, connection: .live).state == .failed)
        let denied = ResourceTablePresentation(rows: [], columns: nil, connection: .failed(.http(code: 403, resource: "pods")))
        #expect(denied.state == .failed && denied.message.contains("Forbidden: pods"))
    }

    @Test func mismatchedCellsFailClosedAndHeaderlessEventsReuseSchema() throws {
        let table = try presentationTable(cells: [#"["first"]"#])
        let event = try presentationTable(columns: "null", cells: [#"["updated"]"#])
        let columns = event.columns(reusing: table.columnDefinitions)
        let value = ResourceTablePresentation(rows: try event.rows.map(ResourceRow.init), columns: columns, connection: .live)
        #expect(value.columns.map(\.definition.name) == ["Arbitrary"])
        #expect(value.rows.first?.cells == ["updated"])
        for schema in [nil, [], try presentationTable(columns: "[]", cells: []).columnDefinitions] {
            let malformed = ResourceTablePresentation(rows: try table.rows.map(ResourceRow.init), columns: schema, connection: .live, selectedUIDs: ["uid-0"])
            #expect(malformed.state == .failed && malformed.rows.isEmpty && malformed.selectedUID == nil)
        }
    }
}

func presentationTable(
    columns: String = #"[{"name":"Arbitrary","type":"string"}]"#,
    cells: [String], uidPrefix: String = "uid"
) throws -> KubernetesTable {
    let rows = cells.enumerated().map { index, cells in
        #"{"cells":\#(cells),"object":{"metadata":{"uid":"\#(uidPrefix)-\#(index)","name":"same-name","namespace":"team","resourceVersion":"v\#(index)"}}}"#
    }.joined(separator: ",")
    return try JSONDecoder().decode(KubernetesTable.self, from: Data("""
    {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"snapshot"},
     "columnDefinitions":\(columns),"rows":[\(rows)]}
    """.utf8))
}

private func present(
    _ table: KubernetesTable, filter: String = "", wide: Bool = false,
    sort: ResourceTablePresentation.Sort? = nil, selected: String? = nil
) throws -> ResourceTablePresentation {
    ResourceTablePresentation(
        rows: try table.rows.map(ResourceRow.init), columns: table.columnDefinitions, connection: .live,
        filter: filter, wide: wide, sort: sort, selectedUIDs: Set(selected.map { [$0] } ?? [])
    )
}

@Suite struct ListedStateTests {
    /// A quiet watch's response is deferred by the apiserver until its first bookmark — about a minute
    /// on an idle namespace — so the snapshot must not be described as if nothing had arrived.
    @Test func aListedSnapshotReadsAsCompleteRatherThanConnecting() throws {
        let table = try presentationTable(cells: [#"["zulu"]"#, #"["alpha"]"#])
        let rows = try table.rows.map(ResourceRow.init)

        let listed = ResourceTablePresentation(rows: rows, columns: table.columnDefinitions, connection: .listed)
        #expect(listed.state == .listed)
        #expect(listed.message == "Listed — 2 of 2 pods. Waiting for live updates to start.")
        #expect(listed.rows.count == 2)

        let empty = ResourceTablePresentation(rows: [], columns: table.columnDefinitions, connection: .listed)
        #expect(empty.message == "Listed — no pods in this namespace. Waiting for live updates to start.")

        let filtered = ResourceTablePresentation(
            rows: rows, columns: table.columnDefinitions, connection: .listed, filter: "alpha"
        )
        #expect(filtered.message == "Listed — 1 of 2 pods. Waiting for live updates to start.")

        // Reconnecting still means the rows may be stale; listing means they are not.
        let reconnecting = ResourceTablePresentation(rows: rows, columns: table.columnDefinitions, connection: .connecting)
        #expect(reconnecting.message.contains("last-known"))
    }
}

@Suite struct SubtitleTests {
    /// The window subtitle is a count and a state, not the pane's sentence.
    @Test func theSubtitleCountsWhatIsShownAgainstWhatExists() throws {
        let table = try presentationTable(cells: [#"["zulu"]"#, #"["alpha"]"#])
        let rows = try table.rows.map(ResourceRow.init)

        #expect(ResourceTablePresentation(rows: rows, columns: table.columnDefinitions, connection: .live).subtitle == "2 pods")
        #expect(ResourceTablePresentation(
            rows: rows, columns: table.columnDefinitions, connection: .live, filter: "alpha"
        ).subtitle == "1 of 2 pods")
        #expect(ResourceTablePresentation(rows: [], columns: table.columnDefinitions, connection: .live).subtitle == "No pods")
        #expect(ResourceTablePresentation(
            rows: rows, columns: table.columnDefinitions, connection: .live, filter: "absent"
        ).subtitle == "No matches")
        #expect(ResourceTablePresentation(rows: rows, columns: table.columnDefinitions, connection: .listed).subtitle == "Listed")
        #expect(ResourceTablePresentation(rows: [], columns: nil, connection: .idle).subtitle == "Not connected")
        #expect(ResourceTablePresentation(
            rows: [], columns: nil, connection: .failed(.invalidRequest)
        ).subtitle == "Failed")
    }
}
