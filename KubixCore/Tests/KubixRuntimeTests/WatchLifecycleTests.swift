import Foundation
import KubixCore
@testable import KubixRuntime
import Observation
import Testing

@Suite @MainActor struct WatchLifecycleTests {
    @Test func realWatchNoOpUpdatesDoNotInvalidateObservedRowsOrColumns() async throws {
        let stream = MemoryByteStream()
        let transport = WatchTestTransport(stream: { _, _ in stream })
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { stream.isWaiting && owner.capture.values.count == 2 }
        let changed = PodObservationFlag()
        withObservationTracking {
            _ = owner.store.rows
            _ = owner.store.columns
        } onChange: { changed.mark() }
        stream.yield(try podEvent())
        try await watchEventually { owner.capture.values.count == 3 && stream.isWaiting }
        #expect(!changed.value)
        stream.yield(Data("""
        {"type":"BOOKMARK","object":{"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"bookmark"},"columnDefinitions":null}}

        """.utf8))
        try await watchEventually { owner.capture.values.count == 4 && stream.isWaiting }
        #expect(!changed.value)
        stream.yield(try podEvent("ADDED", id: 1))
        try await watchEventually { changed.value }
        #expect(owner.store.rows.count == 2)
        await owner.stop()
    }

    @Test func noBookmarkRenewalRetainsHeadersRowsAndLatestOpaqueVersion() async throws {
        let streams = [MemoryByteStream(), MemoryByteStream()]
        let transport = WatchTestTransport(stream: { _, call in streams[call - 1] })
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { streams[0].isWaiting && owner.clock.deadlines == [330] }
        let columns = owner.store.columns
        streams[0].yield(try podEvent(id: 1, version: "z-before-a"))
        try await watchEventually { owner.store.rows.count == 2 && streams[0].isWaiting }
        streams[0].yield(try podEvent(id: 2, version: "a-is-latest"))
        try await watchEventually { owner.store.rows.count == 3 && streams[0].isWaiting }
        owner.clock.advance(to: 300)
        streams[0].yield(nil)
        try await watchEventually { streams[1].isWaiting && owner.clock.deadlines == [630] }
        #expect(owner.store.rows.count == 3 && owner.store.columns == columns && owner.store.connection == .live)
        #expect(await transport.requests.count == 1)
        #expect(await transport.streams.map { podQuery($0)["resourceVersion"] } == ["opaque-list", "a-is-latest"])
        #expect(streams[0].cancelled)
        await owner.stop()
        #expect(streams[1].cancelled && owner.clock.deadlines.isEmpty)
    }

    @Test func blackholedWatchIsCancelledAt330AndBacksOffWithoutDroppingSnapshot() async throws {
        let streams = [MemoryByteStream(), MemoryByteStream()]
        let transport = WatchTestTransport(stream: { _, call in streams[call - 1] })
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { streams[0].isWaiting && owner.clock.deadlines == [330] }
        owner.clock.advance(to: 329)
        #expect(owner.store.connection == .live && !streams[0].cancelled)
        owner.clock.advance(to: 330)
        try await watchEventually { owner.clock.deadlines == [331] }
        #expect(streams[0].cancelled && owner.store.connection == .connecting && owner.store.rows.count == 1)
        #expect(await transport.streams.count == 1)
        owner.clock.advance(to: 331)
        try await watchEventually { streams[1].isWaiting && owner.clock.deadlines == [661] }
        #expect(await transport.requests.count == 1)
        await owner.stop()
        #expect(owner.clock.deadlines.isEmpty && streams[1].cancelled)
    }

    @Test func earlyEOFDoesNotResetRetryBudgetButNormalLeaseDoes() async throws {
        let streams = [MemoryByteStream(), MemoryByteStream(), MemoryByteStream(), MemoryByteStream()]
        let transport = WatchTestTransport(stream: { _, call in streams[call - 1] })
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { streams[0].isWaiting }
        streams[0].yield(nil)
        try await watchEventually { owner.clock.deadlines == [1] }
        owner.clock.advance(to: 1)
        try await watchEventually { streams[1].isWaiting }
        streams[1].yield(nil)
        try await watchEventually { owner.clock.deadlines == [3] }
        owner.clock.advance(to: 3)
        try await watchEventually { streams[2].isWaiting }
        owner.clock.advance(to: 303)
        streams[2].yield(nil)
        try await watchEventually { streams[3].isWaiting }
        streams[3].yield(nil)
        try await watchEventually { owner.clock.deadlines == [304] }
        #expect(owner.store.rows.count == 1 && owner.store.connection == .connecting)
        await owner.stop()
        #expect(owner.clock.deadlines.isEmpty)
    }

    @Test(arguments: [true, false])
    func cancelOrDeadlineDuringResponseHeadersCancelsOpen(_ cancellation: Bool) async throws {
        let gate = TestGate()
        let transport = WatchTestTransport(stream: { _, _ in
            try await gate.wait()
            return MemoryByteStream()
        })
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { await transport.streams.count == 1 && owner.clock.deadlines == [330] }
        // The snapshot is installed and its row is already correct; only the watch is outstanding.
        #expect(owner.store.connection == .listed && owner.store.rows.count == 1)
        if cancellation { await owner.stop() } else {
            owner.clock.advance(to: 330)
            try await watchEventually { owner.clock.deadlines == [331] }
            await owner.stop()
        }
        #expect(await transport.cancelledOpens == 1)
        #expect(owner.clock.deadlines.isEmpty)
    }

    @Test(arguments: [1, 2, 3])
    func contextChangeCancelsAnyPageAndNeverInstallsTheOldSnapshot(_ page: Int) async throws {
        let gate = TestGate()
        let transport = WatchTestTransport { _, call in
            if call == page { try await gate.wait() }
            return try podPage(ids: [call], cursor: call < page ? "\(call)" : "")
        }
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { await transport.requests.count == page }
        try owner.actions.selectContext(named: "second")
        owner.start()
        try await watchEventually { owner.store.connection == .live }
        #expect(await transport.cancelledPages == 1)
        #expect(await transport.requests.count == page + 1)
        #expect(owner.store.rows.map(\.id) == ["uid-\(page + 1)"])
        await owner.stop()
        #expect(owner.clock.deadlines.isEmpty)
    }

    @Test func namespaceChangeCancelsStreamAndRefreshCancelsBackoff() async throws {
        let first = MemoryByteStream()
        let transport = WatchTestTransport(data: { request, call in
            try podPage(ids: [call], namespace: request.path[3])
        }, stream: { _, call in call == 1 ? first : MemoryByteStream(finished: true) })
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { first.isWaiting }
        try owner.actions.selectNamespace("another-team")
        owner.start()
        try await watchEventually { owner.clock.deadlines == [1] }
        #expect(first.cancelled && owner.store.rows.map(\.id) == ["uid-2"])
        owner.actions.refreshPods()
        try await watchEventually { await transport.requests.count == 3 && owner.clock.deadlines == [1] }
        #expect(owner.store.rows.map(\.id) == ["uid-3"])
        await owner.stop()
        #expect(owner.clock.deadlines.isEmpty)
        owner.clock.advance(to: 1_000)
        #expect(await transport.requests.count == 3)
        #expect(await transport.streams.count == 3)
    }

    @Test(arguments: [true, false])
    func uncooperativeLatePageOrStreamCannotOverwriteNewSelection(_ page: Bool) async throws {
        let gate = UncooperativeWatchGate()
        let lateStream = MemoryByteStream()
        let transport = WatchTestTransport(data: { _, call in
            if page, call == 1 { await gate.wait() }
            return try podPage(ids: [call])
        }, stream: { _, call in
            if !page, call == 1 { await gate.wait(); return lateStream }
            return MemoryByteStream()
        })
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { await gate.isWaiting }
        try owner.actions.selectContext(named: "second")
        owner.start()
        try await watchEventually { owner.store.connection == .live && owner.store.rows.map(\.id) == ["uid-2"] }
        await gate.open()
        await owner.stop()
        #expect(owner.store.rows.map(\.id) == ["uid-2"])
        #expect(owner.capture.values.filter { $0.connection == .live }.allSatisfy { $0.rows.map(\.id) == ["uid-2"] })
        if !page { #expect(lateStream.cancelled) }
        #expect(owner.clock.deadlines.isEmpty)
    }
}

actor UncooperativeWatchGate {
    private var waiter: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiter != nil }
    func wait() async { await withCheckedContinuation { waiter = $0 } }
    func open() { waiter?.resume(); waiter = nil }
}

private final class PodObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    var value: Bool { lock.withLock { changed } }
    func mark() { lock.withLock { changed = true } }
}
