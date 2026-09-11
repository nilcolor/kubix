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
        let source = try table.rows.map(PodRow.init)
        let selected = PodTablePresentation(rows: source.reversed(), columns: table.columnDefinitions, connection: .live, selectedUID: "uid-0")
        #expect(selected.selectedUID == "uid-0")
        #expect(try present(table, filter: "another", selected: "uid-0").selectedUID == nil)
        let deleted = PodTablePresentation(rows: Array(source.dropFirst()), columns: table.columnDefinitions, connection: .live, selectedUID: "uid-0")
        #expect(deleted.selectedUID == nil)
        let replaced = try presentationTable(cells: [#"["same"]"#], uidPrefix: "replacement")
        #expect(try present(replaced, selected: "uid-0").selectedUID == nil)
    }

    @Test func emptyIdleConnectingFailedAndLiveAreDistinctAndStaleRowsAreExplicit() throws {
        let empty = try presentationTable(cells: [])
        #expect(try present(empty).state == .empty)
        let table = try presentationTable(cells: [#"["alpha"]"#])
        let rows = try table.rows.map(PodRow.init)
        let cases: [(PodConnection, PodTablePresentation.State)] = [
            (.idle, .idle), (.connecting, .connecting), (.failed(.podAuthentication), .failed), (.live, .live),
        ]
        for (connection, state) in cases {
            let value = PodTablePresentation(rows: rows, columns: table.columnDefinitions, connection: connection)
            #expect(value.state == state)
            if state == .failed || state == .connecting { #expect(value.message.contains("not live")) }
        }
        let connecting = PodTablePresentation(rows: [], columns: nil, connection: .connecting)
        #expect(connecting.state == .connecting && connecting.message.contains("complete"))
        #expect(PodTablePresentation(rows: [], columns: nil, connection: .live).state == .failed)
        let denied = PodTablePresentation(rows: [], columns: nil, connection: .failed(.http(code: 403, resource: "pods")))
        #expect(denied.state == .failed && denied.message.contains("Forbidden: pods"))
    }

    @Test func mismatchedCellsFailClosedAndHeaderlessEventsReuseSchema() throws {
        let table = try presentationTable(cells: [#"["first"]"#])
        let event = try presentationTable(columns: "null", cells: [#"["updated"]"#])
        let columns = event.columns(reusing: table.columnDefinitions)
        let value = PodTablePresentation(rows: try event.rows.map(PodRow.init), columns: columns, connection: .live)
        #expect(value.columns.map(\.definition.name) == ["Arbitrary"])
        #expect(value.rows.first?.cells == ["updated"])
        for schema in [nil, [], try presentationTable(columns: "[]", cells: []).columnDefinitions] {
            let malformed = PodTablePresentation(rows: try table.rows.map(PodRow.init), columns: schema, connection: .live, selectedUID: "uid-0")
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
    sort: PodTablePresentation.Sort? = nil, selected: String? = nil
) throws -> PodTablePresentation {
    PodTablePresentation(
        rows: try table.rows.map(PodRow.init), columns: table.columnDefinitions, connection: .live,
        filter: filter, wide: wide, sort: sort, selectedUID: selected
    )
}

@Suite struct ListedStateTests {
    /// A quiet watch's response is deferred by the apiserver until its first bookmark — about a minute
    /// on an idle namespace — so the snapshot must not be described as if nothing had arrived.
    @Test func aListedSnapshotReadsAsCompleteRatherThanConnecting() throws {
        let table = try presentationTable(cells: [#"["zulu"]"#, #"["alpha"]"#])
        let rows = try table.rows.map(PodRow.init)

        let listed = PodTablePresentation(rows: rows, columns: table.columnDefinitions, connection: .listed)
        #expect(listed.state == .listed)
        #expect(listed.message == "Listed — 2 of 2 pods. Waiting for live updates to start.")
        #expect(listed.rows.count == 2)

        let empty = PodTablePresentation(rows: [], columns: table.columnDefinitions, connection: .listed)
        #expect(empty.message == "Listed — no pods in this namespace. Waiting for live updates to start.")

        let filtered = PodTablePresentation(
            rows: rows, columns: table.columnDefinitions, connection: .listed, filter: "alpha"
        )
        #expect(filtered.message == "Listed — 1 of 2 pods. Waiting for live updates to start.")

        // Reconnecting still means the rows may be stale; listing means they are not.
        let reconnecting = PodTablePresentation(rows: rows, columns: table.columnDefinitions, connection: .connecting)
        #expect(reconnecting.message.contains("last-known"))
    }
}
