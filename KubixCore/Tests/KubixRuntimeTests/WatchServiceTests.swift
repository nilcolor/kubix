import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Suite @MainActor struct WatchServiceTests {
    @Test func all1253PodsFinishThreeBlockedPagesBeforeSnapshotOrWatch() async throws {
        let gates = [TestGate(), TestGate(), TestGate()]
        let transport = WatchTestTransport { request, page in
            #expect(request.path == ["api", "v1", "namespaces", "team", "pods"])
            #expect(request.accept == APIRequest.tableAccept && request.managesCredentialRefresh)
            #expect(podQuery(request) == (page == 1
                ? ["limit": "500", "includeObject": "Metadata"]
                : ["limit": "500", "includeObject": "Metadata", "continue": "cursor-\(page)"]))
            try await gates[page - 1].wait()
            return try podPage(
                ids: Array(((page - 1) * 500)..<min(page * 500, 1253)), cursor: page == 3 ? "" : "cursor-\(page + 1)"
            )
        }
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        for page in 1...3 {
            try await watchEventually { await transport.requests.count == page }
            #expect(await transport.streams.isEmpty)
            #expect(owner.store.rows.isEmpty && owner.store.connection == .connecting)
            #expect(owner.capture.values.isEmpty)
            await gates[page - 1].open()
        }
        try await watchEventually { owner.store.connection == .live }
        #expect(owner.store.rows.count == 1253 && Set(owner.store.rows.map(\.id)).count == 1253)
        #expect(owner.capture.values.map(\.rows.count) == [1253, 1253])
        let request = try #require(await transport.streams.first)
        #expect(request.path == ["api", "v1", "namespaces", "team", "pods"])
        #expect(request.accept == APIRequest.tableAccept && request.managesCredentialRefresh)
        #expect(podQuery(request) == [
            "watch": "true", "allowWatchBookmarks": "true", "timeoutSeconds": "300",
            "includeObject": "Metadata", "resourceVersion": "opaque-list",
        ])
        await owner.stop()
        #expect(owner.clock.deadlines.isEmpty)
    }

    @Test(arguments: [true, false])
    func absentOrEmptyCursorFinishesEvenForEmptyCollection(_ absent: Bool) async throws {
        let transport = WatchTestTransport { _, _ in try podPage(ids: [], cursor: absent ? nil : "") }
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { owner.store.connection == .live }
        #expect(await transport.requests.count == 1)
        #expect(await transport.streams.count == 1)
        #expect(owner.store.rows.isEmpty && owner.store.columns?.count == 1)
        await owner.stop()
    }

    @Test func continuation410DiscardsEverythingAndRestartsAtPageOne() async throws {
        let gate = TestGate()
        let transport = WatchTestTransport { request, call in
            switch call {
            case 1: return try podPage(ids: [91], version: "old", cursor: "expired")
            case 2:
                #expect(podQuery(request)["continue"] == "expired")
                throw APIError.http(code: 410, resource: "pods")
            case 3:
                #expect(podQuery(request)["continue"] == nil)
                try await gate.wait()
                return try podPage(ids: [1], version: "fresh", cursor: "fresh-cursor")
            default:
                #expect(podQuery(request)["continue"] == "fresh-cursor")
                return try podPage(ids: [2], version: "fresh", columns: nil)
            }
        }
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { await transport.requests.count == 3 }
        #expect(owner.store.rows.isEmpty && owner.store.connection == .connecting)
        #expect(await transport.streams.isEmpty)
        await gate.open()
        try await watchEventually { owner.store.connection == .live }
        #expect(owner.store.rows.map(\.id) == ["uid-1", "uid-2"])
        #expect(await transport.streams.map { podQuery($0)["resourceVersion"] } == ["fresh"])
        await owner.stop()
    }

    @Test func repeatedExpirationIsBoundedAcrossFreshPageOneSnapshots() async throws {
        let transport = WatchTestTransport { _, call in
            if call.isMultiple(of: 2) { throw APIError.http(code: 410, resource: "pods") }
            return try podPage(cursor: "always-expired")
        }
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { owner.store.connection == .failed(.watch(.retryLimit)) }
        #expect(await transport.requests.count == 14)
        #expect(await transport.streams.isEmpty)
        #expect(owner.store.rows.isEmpty)
        await owner.stop()
    }

    @Test(arguments: [
        SnapshotFailure.missingResourceVersion, .inconsistentResourceVersion, .missingSchema, .inconsistentSchema,
        .duplicateUID, .cursorCycle, .cursorTooLong, .invalidRow, .malformedTable,
    ])
    func invalidSnapshotsAreExplicitAndNeverPartiallyPublished(_ failure: SnapshotFailure) async throws {
        let transport = WatchTestTransport { _, call in
            switch failure {
            case .missingResourceVersion: return try podPage(version: nil)
            case .missingSchema: return try podPage(columns: nil)
            case .malformedTable: return Data("not-json".utf8)
            case .invalidRow: return try podPage(namespace: "wrong")
            case .cursorTooLong: return try podPage(cursor: String(repeating: "c", count: ResourceSnapshot.maximumCursorBytes + 1))
            case .inconsistentResourceVersion: return try podPage(ids: [call], version: "\(call)", cursor: "next")
            case .inconsistentSchema:
                return try podPage(ids: [call], cursor: call == 1 ? "next" : "", columns: [["name": "\(call)", "type": "string"]])
            case .duplicateUID: return try podPage(cursor: call == 1 ? "next" : "")
            case .cursorCycle: return try podPage(ids: [call], cursor: "loop")
            default: throw TestFailure.missingFixture
            }
        }
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { owner.store.connection == .failed(.snapshot(failure)) }
        #expect(owner.store.rows.isEmpty && owner.store.columns == nil)
        #expect(await transport.streams.isEmpty)
        #expect(owner.capture.values.allSatisfy { $0.rows.isEmpty })
        await owner.stop()
    }

    @Test func uniqueCursorLoopStillHasPageBound() async throws {
        let transport = WatchTestTransport { _, call in try podPage(ids: [], cursor: "\(call)") }
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { owner.store.connection == .failed(.snapshot(.pageLimit)) }
        #expect(await transport.requests.count == ResourceSnapshot.maximumPages)
        #expect(await transport.streams.isEmpty)
        await owner.stop()
    }

    @Test func stream410ClearsRowsAndHeadersBeforeStartingNewPagination() async throws {
        let stream = MemoryByteStream()
        let gate = TestGate()
        let transport = WatchTestTransport(data: { _, call in
            if call > 1 { try await gate.wait() }
            return try podPage(ids: [call], version: "collection-\(call)")
        }, stream: { _, call in call == 1 ? stream : MemoryByteStream() })
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { owner.store.connection == .live }
        stream.yield(podStatus(410))
        try await watchEventually { await transport.requests.count == 2 }
        #expect(owner.store.rows.isEmpty && owner.store.columns == nil && owner.store.connection == .connecting)
        #expect(stream.cancelled)
        await gate.open()
        try await watchEventually { owner.store.connection == .live }
        #expect(owner.store.rows.map(\.id) == ["uid-2"])
        #expect(await transport.streams.map { podQuery($0)["resourceVersion"] } == ["collection-1", "collection-2"])
        await owner.stop()
    }
}
