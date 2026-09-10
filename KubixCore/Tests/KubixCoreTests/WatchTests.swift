import Foundation
import KubixCore
import Testing

// One live metadata-only GET/watch, 2026-09-10, EKS v1.35.6-eks-bca9cf6 (Task12 server version).
// Exact approved pod selector, Table Accept, includeObject=Metadata, sendInitialEvents=true,
// resourceVersionMatch=NotOlderThan, resourceVersion="", allowWatchBookmarks=true, 300s lease.
// Production URLSessionTransport + original cached aws-vault synthetic-profile -> exp chain; no browser.
// ADDED then BOOKMARK arrived within a 45s bound. Only allowlisted/sanitized fields persisted:
// names/UIDs/RVs/time/column names/types/cells replaced, descriptions/format/other metadata removed.
// Bookmark's actual Table envelope, null columns, printed cells and sparse metadata retained.
// Everything constructed by helpers below is SYNTHETIC, not an additional live capture.
struct WatchTests {
    @Test func actualNegotiatedBookmarkIsTableWithSparseRowAndPrintedCells() throws {
        let url = try #require(Bundle.module.url(forResource: "watch-table-captured", withExtension: "jsonl", subdirectory: "Fixtures"))
        var decoder = WatchEventDecoder()
        let bytes = try Data(contentsOf: url)
        let results = decoder.append(bytes)
        #expect(results.count == 2 && decoder.finish().isEmpty)
        guard case .added(let table) = try results[0].get(),
              case .bookmark(let bookmark) = try results[1].get() else { Issue.record("Wrong captured events"); return }
        #expect(table.rows.count == 1 && table.columnDefinitions?.count == 9)
        #expect(bookmark.resourceVersion == "sample-rv")
        let lines = bytes.split(separator: 10)
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(lines[1])) as? [String: Any])
        let object = try #require(envelope["object"] as? [String: Any])
        let sparse = try JSONDecoder().decode(KubernetesTable.self, from: JSONSerialization.data(withJSONObject: object))
        let row = try #require(sparse.rows.first)
        #expect(row.cells.count == 9 && sparse.columnDefinitions == nil)
        #expect(row.object?.metadata?.uid == nil && row.object?.metadata?.name == nil)
        #expect(throws: DecodingError.self) { try PodRow(row: row) }
        var state = try WatchState(rows: [], columns: nil, resourceVersion: "list")
        _ = state.resume()
        #expect(state.receive(try results[0].get()) == .applied)
        let rows = state.rows
        #expect(state.receive(try results[1].get()) == .applied && state.rows == rows)
    }

    @Test(arguments: ["ADDED", "MODIFIED", "DELETED"])
    func dataDiscriminatorsDecodeOnlyTables(_ type: String) throws {
        let line = try watchLine(type, object: watchTableJSON())
        var decoder = WatchEventDecoder()
        #expect(try decoder.append(line)[0].get() == watchEvent(type))
        let invalid = try watchLine(type, object: #"{"apiVersion":"v1","kind":"Status","code":410}"#)
        var bad = WatchEventDecoder()
        #expect(bad.append(invalid) == [.failure(.malformedEvent)])
    }

    @Test(arguments: [
        #"{"type":"BOGUS","object":{}}"#,
        #"{"type":"BOOKMARK","object":{"apiVersion":"v1","kind":"Pod","metadata":{"resourceVersion":"p"}}}"#,
        #"{"type":"ERROR","object":{"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"p"}}}"#,
        #"{"type":"ERROR","object":{"apiVersion":"v1","kind":"Status","status":"Success","code":200}}"#,
        #"{"type":"ERROR","object":{"reason":"Expired"}}"#,
        #"{"type":"ERROR","object":{"apiVersion":"v1","kind":"Status"}}"#,
        #"{"type":"ADDED","object":null}"#,
        #"{"object":{}}"#, #"{"type":42,"object":{}}"#, "null", "[]", "not json", "", "{",
    ])
    func malformedAndUnknownEventsFailExplicitly(_ json: String) {
        var decoder = WatchEventDecoder()
        let results = decoder.append(Data((json + "\n").utf8))
        #expect(results.count == 1)
        #expect(decoder.failure != nil && decoder.bufferedByteCount == 0)
        if json.contains("BOGUS") { #expect(results == [.failure(.unknownEventType)]) }
    }

    @Test(arguments: [true, false])
    func sparseBookmarkAcceptsTableOrRowRVWithoutPodIdentity(_ tableVersion: Bool) throws {
        let metadata = tableVersion ? #""metadata":{"resourceVersion":"opaque-progress"},"# : ""
        let object = """
        {"apiVersion":"meta.k8s.io/v1","kind":"Table",\(metadata)
         "columnDefinitions":null,"rows":[{"cells":["ignored"],
         "object":{"metadata":{"resourceVersion":"opaque-progress"}}}]}
        """
        var decoder = WatchEventDecoder()
        #expect(decoder.append(try watchLine("BOOKMARK", object: object)) == [
            .success(.bookmark(try WatchBookmark(resourceVersion: "opaque-progress"))),
        ])
    }

    @Test(arguments: ["{}", #"{"resourceVersion":""}"#])
    func bookmarkMustHaveNonemptyProgress(_ metadata: String) throws {
        var decoder = WatchEventDecoder()
        let object = #"{"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":\#(metadata)}"#
        #expect(decoder.append(try watchLine("BOOKMARK", object: object)) == [.failure(.invalidPayload)])
        #expect(throws: WatchDecodingError.invalidPayload) { try WatchBookmark(resourceVersion: "") }
    }

    @Test func malformedDataRowPayloadsFailInDecoderToo() throws {
        for rows in [
            "", watchRow(""), watchRow("one", rv: ""),
            watchRow("one") + "," + watchRow("one"), #"{"object":{"metadata":{"resourceVersion":"v"}}}"#,
        ] {
            var decoder = WatchEventDecoder()
            #expect(decoder.append(try watchLine("ADDED", object: watchTableJSON(rows: rows))) == [.failure(.invalidPayload)])
        }
        var status = WatchEventDecoder()
        let object = """
        {"apiVersion":"v1","kind":"Status","reason":"Expired","details":{"retryAfterSeconds":3,
         "causes":[{"reason":"HistoryUnavailable","message":"synthetic","field":"resourceVersion"}]}}
        """
        guard case .error(let decoded) = try status.append(watchLine("ERROR", object: object))[0].get() else {
            Issue.record("Expected Status"); return
        }
        #expect(decoded.reason == "Expired" && decoded.code == nil)
        #expect(decoded.details?.retryAfterSeconds == 3 && decoded.details?.causes?.first?.field == "resourceVersion")
    }

    @Test func everyPossibleUTF8SplitAndBytewiseInputRetainsOrder() throws {
        let bytes = try watchLine("ADDED", object: watchTableJSON(rv: "opaque-雪🌍"))
            + watchLine("MODIFIED", object: watchTableJSON(rv: "opaque-previous"))
        let expected: [Result<WatchEvent, WatchDecodingError>] = [
            .success(try watchEvent("ADDED", rv: "opaque-雪🌍")), .success(try watchEvent("MODIFIED", rv: "opaque-previous")),
        ]
        for split in 0...bytes.count {
            var decoder = WatchEventDecoder()
            let results = decoder.append(Data(bytes.prefix(split))) + decoder.append(Data(bytes.dropFirst(split)))
            #expect(results == expected)
            #expect(decoder.finish().isEmpty)
        }
        var decoder = WatchEventDecoder()
        let results = bytes.flatMap { decoder.append(Data([$0])) }
        #expect(results == expected && decoder.finish().isEmpty)
    }

    @Test func coalescedValidMalformedValidReturnsValidPrefixThenFailureWithoutSkipping() throws {
        let line = try watchLine("ADDED", object: watchTableJSON())
        var decoder = WatchEventDecoder()
        #expect(decoder.append(line + Data("not-json\n".utf8) + line) == [
            .success(try watchEvent("ADDED")), .failure(.malformedEvent),
        ])
        #expect(decoder.append(line) == [.failure(.malformedEvent)])
        #expect(decoder.finish() == [.failure(.malformedEvent)])
    }

    @Test func invalidUTF8EvenSplitAcrossChunksIsNotLossilyRepaired() throws {
        let line = try watchLine("ADDED", object: watchTableJSON())
        var decoder = WatchEventDecoder()
        #expect(decoder.append(line + Data([0xF0, 0x9F])) == [.success(try watchEvent("ADDED"))])
        #expect(decoder.append(Data([0xFF, 10])) == [.failure(.invalidUTF8)])
    }

    @Test func exactByteLimitCRLFAndOverflowAfterValidPrefix() throws {
        let bytes = try watchLine("ADDED", object: watchTableJSON())
        let limit = bytes.count - 1
        var exact = WatchEventDecoder(maximumLineBytes: limit)
        #expect(exact.append(bytes) == [.success(try watchEvent("ADDED"))] && exact.finish().isEmpty)
        var crlf = WatchEventDecoder(maximumLineBytes: limit + 1)
        #expect(crlf.append(Data(bytes.dropLast()) + Data([13, 10])) == [.success(try watchEvent("ADDED"))])
        var overflow = WatchEventDecoder(maximumLineBytes: limit)
        #expect(overflow.append(bytes + Data(repeating: 65, count: limit + 1)) == [
            .success(try watchEvent("ADDED")), .failure(.lineTooLong(limit: limit)),
        ])
        #expect(overflow.bufferedByteCount == 0)
        var split = WatchEventDecoder(maximumLineBytes: limit)
        #expect(split.append(Data(repeating: 65, count: limit)).isEmpty && split.bufferedByteCount == limit)
        #expect(split.append(Data([65])) == [.failure(.lineTooLong(limit: limit))])
    }

    @Test func eofRequiresDelimiterEvenForOtherwiseCompleteJSON() throws {
        let bytes = try watchLine("ADDED", object: watchTableJSON())
        for suffix in [Data(bytes.dropLast()), Data("{".utf8), Data([0xF0]), Data(" \r".utf8)] {
            var decoder = WatchEventDecoder()
            #expect(decoder.append(bytes + suffix) == [.success(try watchEvent("ADDED"))])
            #expect(decoder.finish() == [.failure(.truncatedEOF)])
            #expect(decoder.bufferedByteCount == 0)
        }
        var empty = WatchEventDecoder()
        #expect(empty.finish().isEmpty)
        #expect(empty.append(bytes) == [.failure(.decoderClosed)])
        #expect(empty.finish() == [.failure(.decoderClosed)])
    }
}

func watchRow(_ uid: String = "one", rv: String = "rv", cells: String = #"["sample"]"#) -> String {
    // Encode string values rather than interpolating opaque RVs into JSON.
    let metadata = ["uid": uid, "name": "same-name", "namespace": "sample", "resourceVersion": rv]
    let json = String(decoding: try! JSONEncoder().encode(metadata), as: UTF8.self)
    return #"{"cells":\#(cells),"object":{"metadata":\#(json)}}"#
}

func watchTableJSON(rv: String? = nil, columns: String? = nil, rows: String? = nil) -> String {
    let metadata = rv.map { #","metadata":{"resourceVersion":\#(String(decoding: try! JSONEncoder().encode($0), as: UTF8.self))}"# } ?? ""
    let schema = columns.map { #","columnDefinitions":\#($0)"# } ?? ""
    return #"{"apiVersion":"meta.k8s.io/v1","kind":"Table"\#(metadata)\#(schema),"rows":[\#(rows ?? watchRow(rv: rv ?? "rv"))]}"#
}

func watchTable(rv: String? = nil, columns: String? = nil, rows: String? = nil) throws -> KubernetesTable {
    try JSONDecoder().decode(KubernetesTable.self, from: Data(watchTableJSON(rv: rv, columns: columns, rows: rows).utf8))
}

func watchLine(_ type: String, object: String) throws -> Data {
    let payload = try JSONSerialization.jsonObject(with: Data(object.utf8), options: [.fragmentsAllowed])
    return try JSONSerialization.data(withJSONObject: ["type": type, "object": payload], options: [.sortedKeys]) + Data([10])
}

func watchEvent(_ type: String, rv: String? = nil) throws -> WatchEvent {
    try JSONDecoder().decode(WatchEvent.self, from: watchLine(type, object: watchTableJSON(rv: rv)))
}

let watchColumns = #"[{"name":"Name","type":"string"}]"#

func watchState() throws -> WatchState {
    let table = try watchTable(columns: watchColumns)
    var state = try WatchState(rows: table.rows.map(PodRow.init), columns: table.columnDefinitions, resourceVersion: "list-rv")
    #expect(state.resume() == .watch(resourceVersion: "list-rv"))
    return state
}

func watchStatus(_ code: Int? = nil, reason: String = "Unknown", details: String = "null") throws -> KubernetesStatus {
    let codeField = code.map { #","code":\#($0)"# } ?? ""
    let json = #"{"apiVersion":"v1","kind":"Status","status":"Failure","reason":"\#(reason)","details":\#(details)\#(codeField)}"#
    return try JSONDecoder().decode(KubernetesStatus.self, from: Data(json.utf8))
}
