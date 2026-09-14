import Foundation
@testable import KubixCore
import KubixRuntime
import Testing

@Suite @MainActor struct LogCancellationTests {
    enum Change: CaseIterable, Sendable {
        case row, deleted, replaced, selection, filter, context, namespace, reload, refresh, close, shutdown
    }

    @Test(arguments: Change.allCases, [true, false])
    func staleDetailsOrStreamOpenCannotResurrectLog(change: Change, detail: Bool) async throws {
        let gate = UncooperativeWatchGate()
        let bytes = MemoryByteStream([Data("not-delivered\n".utf8)])
        let transport = LogTestTransport(
            data: { _, _ in if detail { await gate.wait() }; return try podDetailsData() },
            stream: { _, _ in if !detail { await gate.wait() }; return bytes }
        )
        let owner = try PodShellTestOwner(transport: transport, logs: LogService { _ in transport })
        owner.actions.openPodLogs(uid: "uid-0", container: "web")
        try await watchEventually { await gate.isWaiting }
        try await mutate(change, owner: owner)
        await gate.open()
        try await watchEventually { owner.actions.podDetailTasks.isEmpty && owner.actions.logTasks.isEmpty }
        #expect(owner.store.logSessions.allSatisfy { $0.state != .following && !$0.buffer.lines.contains { $0.text == "not-delivered" } })
        if detail { #expect(await transport.streams.isEmpty) } else { #expect(bytes.cancelled) }
        await owner.actions.shutdownAndWait()
    }

    private func mutate(_ change: Change, owner: PodShellTestOwner) async throws {
        switch change {
        case .row, .deleted, .replaced: try mutateRow(change, owner: owner)
        case .selection: owner.actions.selectPod(uid: "uid-1"); owner.actions.selectPod(uid: "uid-0")
        case .filter: owner.actions.setPodFilter("pod-1")
        case .context: try owner.actions.selectContext(named: "second")
        case .namespace: try owner.actions.selectNamespace("other")
        case .reload: await owner.actions.loadConfiguration()
        case .refresh: owner.actions.refreshPods()
        case .close:
            if let id = owner.store.logSessions.first?.id { owner.actions.closeLog(id) } else { owner.actions.selectPod(uid: nil) }
        case .shutdown: owner.actions.shutdown()
        }
    }

    private func mutateRow(_ change: Change, owner: PodShellTestOwner) throws {
        if change == .row { try owner.changeRow(); return }
        if change == .deleted { try owner.install(ids: [1]); return }
        let bytes = String(decoding: try podPage(ids: [0]), as: UTF8.self).replacingOccurrences(of: "uid-0", with: "replacement")
        let table = try JSONDecoder().decode(KubernetesTable.self, from: Data(bytes.utf8))
        owner.actions.applyPodUpdate(.init(rows: try table.rows.map { try PodRow(row: $0) }, columns: table.columnDefinitions, connection: .live))
    }

    @Test func supersededDetailsAndOldMenuCannotReplaceNewSession() async throws {
        let gate = UncooperativeWatchGate()
        let bytes = MemoryByteStream()
        let transport = LogTestTransport(data: { _, call in
            if call == 1 { await gate.wait(); throw APIError.http(code: 403, resource: "old") }
            return try podDetailsData()
        }, stream: { _, _ in bytes })
        let owner = try PodShellTestOwner(transport: transport, logs: LogService { _ in transport })
        let menu = owner.actions.podLogsMenuAction(uid: "uid-0")
        owner.actions.openPodLogs(uid: "uid-0", container: "web")
        try await watchEventually { await gate.isWaiting }
        owner.actions.openPodLogs(uid: "uid-0", container: "web")
        try await watchEventually { bytes.isWaiting }
        menu()
        await gate.open()
        try await watchEventually { owner.actions.podDetailTasks.isEmpty }
        #expect(owner.store.logSessions.count == 1 && owner.store.podLogDiagnostic == nil)
        #expect(await transport.requests.count == 2)
        await owner.actions.shutdownAndWait()
    }

    @Test(arguments: [true, false])
    func cancellingResumeDetailsPreventsNewSegmentOrSwitch(close: Bool) async throws {
        let gate = UncooperativeWatchGate()
        let bytes = MemoryByteStream()
        let transport = LogTestTransport(data: { _, call in
            if call > 1 { await gate.wait() }
            return try podDetailsData()
        }, stream: { _, _ in bytes })
        let owner = try PodShellTestOwner(transport: transport, logs: LogService { _ in transport })
        owner.actions.openPodLogs(uid: "uid-0", container: "web")
        try await watchEventually { bytes.isWaiting }
        let session = try #require(owner.store.logSessions.first)
        owner.actions.switchLogContainer(session.id, name: "setup")
        try await watchEventually { await gate.isWaiting }
        if close { owner.actions.closeLog(session.id) } else { await owner.actions.loadConfiguration() }
        await gate.open()
        try await watchEventually { owner.actions.logTasks.isEmpty }
        #expect(session.segment == 1)
        #expect(await transport.streams.count == 1)
        #expect(owner.store.logSessions.count == (close ? 0 : 1))
        await owner.actions.shutdownAndWait()
    }

    @Test func supersededResumeCannotAppendAnotherSegmentOrOverrideCurrentState() async throws {
        let gate = UncooperativeWatchGate()
        let first = MemoryByteStream()
        let second = MemoryByteStream()
        let transport = LogTestTransport(data: { _, call in
            if call == 2 { await gate.wait(); throw APIError.http(code: 404, resource: "old") }
            return try podDetailsData()
        }, stream: { _, call in call == 1 ? first : second })
        let owner = try PodShellTestOwner(transport: transport, logs: LogService { _ in transport })
        owner.actions.openPodLogs(uid: "uid-0", container: "web")
        try await watchEventually { first.isWaiting }
        let session = try #require(owner.store.logSessions.first)
        owner.actions.resumeLog(session.id)
        try await watchEventually { await gate.isWaiting }
        owner.actions.resumeLog(session.id)
        try await watchEventually { second.isWaiting && session.state == .following }
        await gate.open()
        try await watchEventually { owner.actions.logTasks.count == 1 }
        #expect(session.state == .following && session.segment == 2)
        #expect(await transport.requests.count == 3)
        #expect(await transport.streams.count == 2)
        await owner.actions.shutdownAndWait()
    }

    @Test func blockedConfigurationReloadRejectsNewLogsAndResumeUntilFinished() async throws {
        let gate = UncooperativeWatchGate()
        let bytes = MemoryByteStream()
        let transport = LogTestTransport(stream: { _, _ in bytes })
        let owner = try PodShellTestOwner(transport: transport, logs: LogService { _ in transport })
        owner.actions.openPodLogs(uid: "uid-0", container: "web")
        try await watchEventually { bytes.isWaiting }
        let session = try #require(owner.store.logSessions.first)
        await owner.configuration.block(on: gate)
        let reload = Task { await owner.actions.loadConfiguration() }
        try await watchEventually { await gate.isWaiting }
        owner.actions.resumeLog(session.id)
        #expect(session.state == .failed(.unavailable))
        owner.actions.openPodLogs(uid: "uid-0", container: "web")
        #expect(owner.store.podLogDiagnostic != nil && owner.store.logSessions.count == 1)
        #expect(await transport.requests.count == 1)
        await gate.open()
        await reload.value
        await owner.actions.shutdownAndWait()
    }
}
