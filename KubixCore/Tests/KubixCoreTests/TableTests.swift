import Foundation
import KubixCore
import Testing

// Captured is a sanitized, metadata-only Table from the authorized EKS target (2026-09-10).
// Other table-pods fixtures are synthetic mutations, not claims of captured watch/bookmark events.
struct TableTests {
    @Test func capturedColumnsCellsAndMetadataKeepServerOrder() throws {
        let table = try fixture("captured")
        let columns = try #require(table.columnDefinitions)
        let row = try #require(table.rows.first)
        let pod = try ResourceRow(row: row)
        #expect(table.apiVersion == "meta.k8s.io/v1" && table.kind == "Table")
        #expect(columns.map(\.name) == ["Name", "Ready", "Status", "Restarts", "Age", "IP", "Node", "Nominated Node", "Readiness Gates"])
        #expect(columns.map(\.type) == Array(repeating: "string", count: 9))
        #expect(columns.map(\.priority) == [0, 0, 0, 0, 0, 1, 1, 1, 1])
        #expect(columns[0].format == "name" && columns[0].description?.isEmpty == false)
        #expect(try pod.displayCells(using: columns) == ["sample-pod", "1/1", "Running", "0", "1h"])
        #expect(try pod.displayCells(using: columns, wide: true) == [
            "sample-pod", "1/1", "Running", "0", "1h", "192.0.2.10", "sample-node", "<none>", "<none>",
        ])
        #expect(row.object?.kind == "PartialObjectMetadata")
        #expect(pod.id == "11111111-2222-4333-8444-555555555555")
        #expect(pod.metadata.uid == pod.id && pod.metadata.name == "sample-pod")
        #expect(pod.metadata.namespace == "sample-namespace")
        #expect(pod.metadata.resourceVersion == "rv-pod-90")
        #expect(pod.metadata.creationTimestamp == Date(timeIntervalSince1970: 1_767_323_045))
        #expect(table.metadata?.resourceVersion == "rv-list-100" && table.metadata?.continuation == nil)
    }

    @Test func heterogeneousCellsPreserveTypesAndDisplayWithoutColumnDrivenLoss() throws {
        let table = try fixture("cells")
        let row = try #require(table.rows.first)
        #expect(row.cells == [
            .string("display-name-is-not-identity"), .number(7), .string("007"), .boolean(true), .null, .number(1.25),
            .array([.string("two"), .number(2), .boolean(false), .null]),
            .object(["z": .boolean(false), "a": .number(1)]),
            .number(try #require(Decimal(string: "18446744073709551615"))), .number(-17), .boolean(false),
            .string("line\n\"quoted\" 雪"),
        ])
        #expect(row.cells.map(\.displayText) == [
            "display-name-is-not-identity", "7", "007", "true", "", "1.25",
            #"["two",2,false,null]"#, #"{"a":1,"z":false}"#,
            "18446744073709551615", "-17", "false", "line\n\"quoted\" 雪",
        ])
        let encoded = try JSONEncoder().encode(row.cells)
        #expect(try JSONDecoder().decode([TableCell].self, from: encoded) == row.cells)
        let pod = try ResourceRow(row: row)
        #expect(pod.id == "opaque-pod-uid" && pod.metadata.name == "sample-pod")
        #expect(pod.metadata.creationTimestamp == Date(timeIntervalSince1970: 1_767_323_045.125))
    }

    @Test func interleavedWideColumnsDoNotShiftCellsAndUnknownTypesStillDisplay() throws {
        let table = try fixture("cells")
        let columns = try #require(table.columnDefinitions)
        let pod = try ResourceRow(row: #require(table.rows.first))
        #expect(columns[0].priority == 0)
        #expect(columns[1].isWideOnly && columns[6].isWideOnly)
        #expect(!columns[9].isWideOnly)
        #expect(columns[7].type == "future-custom-type")
        #expect(try pod.displayCells(using: columns) == [
            "display-name-is-not-identity", "007", "true", "", "1.25", #"{"a":1,"z":false}"#,
            "18446744073709551615", "-17", "false", "line\n\"quoted\" 雪",
        ])
        #expect(try pod.displayCells(using: columns, wide: true) == pod.cells.map(\.displayText))
    }

    @Test func listContinuationAndResourceVersionsAreOpaqueAndIndependentOfRows() throws {
        let table = try fixture("continuation")
        #expect(table.metadata?.continuation == "opaque+/= page-token")
        #expect(table.metadata?.resourceVersion == "rv-list-100")
        #expect(table.rows.first?.object?.metadata?.resourceVersion == "rv-pod-90")
        let empty = try fixture("empty")
        #expect(empty.rows.isEmpty)
        #expect(empty.columnDefinitions?.map(\.name) == ["Name"])
        #expect(empty.metadata?.continuation == "")
        #expect(empty.metadata?.resourceVersion == table.metadata?.resourceVersion)
    }

    @Test(arguments: ["", #","rows":null"#, #","rows":[]"#])
    func emptyRowsAcceptGoOmissionAndNullWithoutDroppingMetadata(_ rows: String) throws {
        let table = try decode(#"{"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"opaque"}}"#.dropLast() + rows + "}")
        #expect(table.rows.isEmpty && table.metadata?.resourceVersion == "opaque")
    }

    @Test(arguments: ["watch-missing-columns", "watch-null-columns"])
    func absentWatchSchemaReusesListColumnsWithoutInventingAnEmptySchema(_ name: String) throws {
        let list = try fixture("captured")
        let event = try fixture(name)
        #expect(event.columnDefinitions == nil)
        #expect(event.columns(reusing: nil) == nil)
        #expect(event.columns(reusing: list.columnDefinitions) == list.columnDefinitions)
        let pod = try ResourceRow(row: #require(event.rows.first))
        let original = try ResourceRow(row: #require(list.rows.first))
        #expect(pod.id == original.id)
        #expect(pod.metadata.resourceVersion == "rv-pod-101")
        #expect(try pod.displayCells(using: #require(event.columns(reusing: list.columnDefinitions))) == [
            "sample-pod", "1/1", "Running", "1", "2h",
        ])
    }

    @Test func suppliedSchemasIncludingEmptyReplaceRatherThanReusePreviousColumns() throws {
        let previous = try fixture("captured").columnDefinitions
        let empty = try decode(#"{"apiVersion":"meta.k8s.io/v1","kind":"Table","columnDefinitions":[]}"#)
        #expect(empty.columnDefinitions == [])
        #expect(empty.columns(reusing: previous) == [])
        let replacement = try fixture("cells")
        #expect(replacement.columns(reusing: previous) == replacement.columnDefinitions)
        #expect(replacement.columns(reusing: previous) != previous)
        let list = try fixture("captured")
        #expect(list.columns(reusing: nil) == previous)
    }

    @Test func sparseProgressMetadataDoesNotRequireOrManufacturePodIdentity() throws {
        let table = try fixture("sparse-metadata")
        let row = try #require(table.rows.first)
        let metadata = try #require(row.object?.metadata)
        #expect(row.cells.isEmpty)
        #expect(metadata.resourceVersion == "rv-progress-only")
        #expect(metadata.uid == nil && metadata.name == nil && metadata.namespace == nil)
        #expect(metadata.creationTimestamp == nil)
        #expect(throws: DecodingError.self) { try ResourceRow(row: row) }
    }

    @Test(arguments: [
        "{}", #"{"object":null}"#, #"{"object":{}}"#, #"{"object":{"metadata":null}}"#,
        #"{"object":{"metadata":{}}}"#, #"{"object":{"metadata":{"uid":null,"name":null,"namespace":null}}}"#,
    ])
    func absentMetadataAndCellsRemainSparseButCannotMaterializePods(_ json: String) throws {
        let row = try JSONDecoder().decode(KubernetesTable.Row.self, from: Data(json.utf8))
        #expect(row.cells.isEmpty)
        #expect(throws: DecodingError.self) { try ResourceRow(row: row) }
    }

    @Test(arguments: [#"null"#, #""""#, #"" ""#, #""uid with space""#, #""uid\n""#, #""uid\u0000""#])
    func missingEmptyAndInvalidUIDsCannotBecomeResourceRows(_ uid: String) throws {
        let json = #"{"cells":["not-a-uid"],"object":{"metadata":{"uid":"# + uid + #","name":"sample-pod"}}}"#
        let row = try JSONDecoder().decode(KubernetesTable.Row.self, from: Data(json.utf8))
        #expect(throws: DecodingError.self) { try ResourceRow(row: row) }
    }

    @Test func deleteRecreateUsesUIDNotNameNamespaceOrDisplayCells() throws {
        func row(_ uid: String, _ display: String) throws -> ResourceRow {
            let json = #"{"cells":["\#(display)"],"object":{"metadata":{"uid":"\#(uid)","name":"same-name","namespace":"same-ns"}}}"#
            return try ResourceRow(row: JSONDecoder().decode(KubernetesTable.Row.self, from: Data(json.utf8)))
        }
        let first = try row("opaque-uid-1", "old")
        let changed = try row("opaque-uid-1", "new")
        let recreated = try row("opaque-uid-2", "old")
        #expect(first.id == changed.id && first.cells != changed.cells)
        #expect(first.id != recreated.id && first.metadata.name == recreated.metadata.name)
    }

    @Test func schemaCellCountMismatchFailsVisiblyRatherThanTruncating() throws {
        let table = try fixture("captured")
        let pod = try ResourceRow(row: #require(table.rows.first))
        let columns = try #require(table.columnDefinitions)
        #expect(throws: DecodingError.self) { try pod.displayCells(using: Array(columns.dropLast())) }
        #expect(throws: DecodingError.self) { try pod.displayCells(using: columns + columns, wide: true) }
    }

    @Test(arguments: ["2026-02-30T00:00:00Z", "2026-01-02", "not-a-date", "2026-01-02T25:00:00Z"])
    func malformedCreationTimesAreRejectedUsingSharedTimestampParser(_ timestamp: String) throws {
        let json = #"{"creationTimestamp":"\#(timestamp)"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(KubernetesObjectMetadata.self, from: Data(json.utf8))
        }
    }

    @Test(arguments: [
        #"{"kind":"Status","apiVersion":"v1"}"#,
        #"{"kind":"Table","apiVersion":"meta.k8s.io/v2"}"#,
        #"{"kind":"Table"}"#,
        #"{"kind":"Table","apiVersion":"meta.k8s.io/v1","columnDefinitions":{}}"#,
        #"{"kind":"Table","apiVersion":"meta.k8s.io/v1","columnDefinitions":[{"name":"Count","type":"integer","priority":"wide"}]}"#,
        #"{"kind":"Table","apiVersion":"meta.k8s.io/v1","rows":[{"cells":{}}]}"#,
        #"{"kind":"Table","apiVersion":"meta.k8s.io/v1","rows":[{"object":{"metadata":{"uid":123}}}]}"#,
        #"{"kind":"Table","apiVersion":"meta.k8s.io/v1","metadata":{"resourceVersion":123}}"#,
        #"{"kind":"Table","apiVersion":"meta.k8s.io/v1","metadata":{"continue":[]}}"#,
    ])
    func malformedTablesAreNotSilentlyTreatedAsEmptySnapshots(_ json: String) {
        #expect(throws: DecodingError.self) { try decode(json) }
    }

    @Test func unknownObjectFieldsDoNotBecomePartOfTheResourceModel() throws {
        let json = """
        {"cells":["sample"],"object":{"apiVersion":"v1","kind":"Pod",
         "metadata":{"uid":"opaque","annotations":{"synthetic":"ignored"}},
         "spec":{"containers":[{"name":"ignored"}]},"status":{"phase":"ignored"}}}
        """
        let row = try JSONDecoder().decode(KubernetesTable.Row.self, from: Data(json.utf8))
        #expect(try ResourceRow(row: row).id == "opaque")
        #expect(!String(reflecting: row).contains("ignored"))
    }

    private func fixture(_ suffix: String) throws -> KubernetesTable {
        let url = try #require(Bundle.module.url(forResource: "table-pods-" + suffix, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(KubernetesTable.self, from: Data(contentsOf: url))
    }

    private func decode(_ json: String) throws -> KubernetesTable {
        try JSONDecoder().decode(KubernetesTable.self, from: Data(json.utf8))
    }
}
