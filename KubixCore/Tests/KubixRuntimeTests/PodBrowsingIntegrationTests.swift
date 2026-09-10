import Foundation
import KubixCore
import Testing

@Suite @MainActor struct PodBrowsingIntegrationTests {
    @Test func realWatchKeepsSortColumnsAndUIDUntilDeletionButReplacementNeverInheritsSelection() async throws {
        let stream = MemoryByteStream()
        let transport = WatchTestTransport(data: { _, _ in try podPage(ids: [0, 1]) }, stream: { _, _ in stream })
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { owner.store.connection == .live }
        owner.actions.selectPod(uid: "uid-0")
        owner.actions.sortPods(.init(column: 0, ascending: false))
        #expect(owner.store.podTable.rows.map(\.id) == ["uid-1", "uid-0"])
        let modified = String(decoding: try podEvent(version: "modified"), as: UTF8.self)
            .replacingOccurrences(of: #""cells":["pod-0"]"#, with: #""cells":["updated"]"#)
        stream.yield(Data(modified.utf8))
        try await watchEventually { owner.store.rows.first?.cells.first == .string("updated") }
        #expect(owner.store.podTable.columns.map(\.definition.name) == ["Name"])
        #expect(owner.store.podTable.rows.map(\.id) == ["uid-0", "uid-1"])
        #expect(owner.store.selectedPodUID == "uid-0")
        stream.yield(try podEvent("DELETED", version: "deleted"))
        try await watchEventually { owner.store.rows.count == 1 }
        #expect(owner.store.selectedPodUID == nil)
        let replacement = """
        {"type":"ADDED","object":{"apiVersion":"meta.k8s.io/v1","kind":"Table","rows":[
        {"cells":["pod-0"],"object":{"metadata":{"uid":"replacement","name":"pod-0","namespace":"team","resourceVersion":"replaced"}}}]}}
        """.replacingOccurrences(of: "\n", with: "")
        stream.yield(Data((replacement + "\n").utf8))
        try await watchEventually { owner.store.rows.count == 2 }
        #expect(owner.store.selectedPodUID == nil && owner.store.podSort?.ascending == false)
        owner.actions.selectPod(uid: "replacement")
        owner.actions.setPodFilter("pod-1")
        #expect(owner.store.selectedPodUID == nil)
        await owner.stop()
        #expect(stream.cancelled && owner.clock.deadlines.isEmpty)
    }

    @Test func failedSecondPageCannotPresentItsFirstPageAsLiveOrEmptySuccess() async throws {
        let gate = TestGate()
        let transport = WatchTestTransport { _, call in
            if call == 1 { return try podPage(cursor: "next") }
            try await gate.wait()
            throw APIError.http(code: 403, resource: "pods")
        }
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { await transport.requests.count == 2 }
        #expect(owner.store.podTable.state == .connecting && owner.store.podTable.rows.isEmpty)
        owner.actions.selectPod(uid: "uid-0")
        #expect(owner.store.selectedPodUID == nil)
        await gate.open()
        try await watchEventually { owner.store.podTable.state == .failed }
        #expect(owner.store.podTable.rows.isEmpty && owner.store.podTable.message.contains("Forbidden: pods"))
        #expect(await transport.streams.isEmpty)
        await owner.stop()
    }
}
