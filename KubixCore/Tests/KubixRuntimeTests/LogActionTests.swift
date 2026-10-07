import Foundation
@testable import KubixCore
import KubixRuntime
import Testing

@Suite @MainActor struct LogActionTests {
    @Test func rowFlowFetchesFreshDetailsSelectsEligibleDefaultAndKeepsExecStable() async throws {
        let bytes = MemoryByteStream([Data("synthetic\n".utf8)])
        let transport = LogTestTransport(data: { _, _ in try podDetailsData(annotation: "setup") }, stream: { _, _ in bytes })
        let owner = try PodShellTestOwner(transport: transport, logs: LogService { _ in transport })
        owner.actions.openPodShell(uid: "uid-0")
        try await watchEventually { owner.store.execSessions.first?.state == .running }
        let shell = try #require(owner.store.execSessions.first)
        let surface = owner.actions.surface(for: shell.id)
        owner.actions.openPodLogs(uid: "uid-0", container: "web")
        try await watchEventually { owner.store.logSessions.first?.buffer.count == 2 }
        let log = try #require(owner.store.logSessions.first)
        #expect(log.scope.subject.uid == "uid-0" && log.scope.container.name == "web")
        #expect(log.containers.map(\.kind) == [.regular, .regular, .initContainer, .ephemeral])
        #expect(owner.store.selectedSession == .logs(log.id))
        owner.actions.selectShell(shell.id)
        #expect(owner.store.selectedSession == .shell(shell.id))
        #expect(log.state == .following && owner.actions.surface(for: shell.id) === surface)
        owner.actions.selectLog(log.id)
        #expect(owner.store.execSessions.first?.target == shell.target)
        owner.actions.setLogFilter(log.id, String(repeating: "x", count: 1000))
        #expect(log.filter.count == 256 && log.buffer.count == 2)
        #expect(await transport.requests.count == 2)
        #expect(await transport.purposes == [.logs])
        owner.actions.closeLog(log.id)
        #expect(log.buffer.count == 0 && owner.actions.surface(for: shell.id) === surface)
        await owner.actions.shutdownAndWait()
        #expect(bytes.cancelled && owner.actions.logTasks.isEmpty)
    }

    @Test func pauseResumeRequiresFreshUIDAndAddsVisibleNewTailBoundary() async throws {
        let first = MemoryByteStream([Data("first\npartial".utf8)])
        let second = MemoryByteStream([Data("second\n".utf8)], finished: true)
        let transport = LogTestTransport(stream: { _, call in call == 1 ? first : second })
        let owner = try PodShellTestOwner(transport: transport, logs: LogService { _ in transport })
        owner.actions.openPodLogs(uid: "uid-0", container: "web")
        try await watchEventually { first.isWaiting }
        let session = try #require(owner.store.logSessions.first)
        let scope = session.scope
        owner.actions.pauseLog(session.id)
        try await watchEventually { owner.actions.logTasks.isEmpty }
        #expect(session.state == .paused && first.cancelled)
        #expect(session.buffer.lines.last?.text == "partial")
        owner.actions.resumeLog(session.id)
        try await watchEventually { session.state == .completed }
        #expect(owner.store.logSessions.count == 1 && session.scope == scope && session.segment == 2)
        #expect(session.buffer.lines.filter(\.isBoundary).count == 2)
        #expect(session.buffer.lines.contains { $0.text == "first" } && session.buffer.lines.last?.text == "second")
        #expect(await transport.requests.count == 2)
        #expect(await transport.streams.count == 2)
        #expect(LogSession.replayNotice.contains("missing or duplicated"))
        await owner.actions.shutdownAndWait()
    }

    @Test(arguments: [true, false])
    func resumeOrSwitchNeverAdoptsReplacement(switching: Bool) async throws {
        let bytes = MemoryByteStream([Data("kept\n".utf8)])
        let transport = LogTestTransport(
            data: { _, call in try podDetailsData(uid: call == 1 ? "uid-0" : "replacement") },
            stream: { _, _ in bytes }
        )
        let owner = try PodShellTestOwner(transport: transport, logs: LogService { _ in transport })
        owner.actions.openPodLogs(uid: "uid-0", container: "web")
        try await watchEventually { bytes.isWaiting }
        let session = try #require(owner.store.logSessions.first)
        if switching { owner.actions.switchLogContainer(session.id, name: "setup") } else { owner.actions.resumeLog(session.id) }
        try await watchEventually { session.state == .failed(.replaced) }
        #expect(session.scope.subject.uid == "uid-0" && session.segment == 1 && owner.store.logSessions.count == 1)
        #expect(session.buffer.lines.last?.text == "kept")
        #expect(await transport.streams.count == 1)
        await owner.actions.shutdownAndWait()
    }

    @Test(arguments: ["waiting", "setup", "debugger"])
    func containerSwitchCancelsAndCreatesDistinctImmutableTarget(_ name: String) async throws {
        let first = MemoryByteStream([Data("old\n".utf8)])
        let next = MemoryByteStream([Data("new\n".utf8)])
        let transport = LogTestTransport(stream: { _, call in call == 1 ? first : next })
        let owner = try PodShellTestOwner(transport: transport, logs: LogService { _ in transport })
        owner.actions.openPodLogs(uid: "uid-0", container: "web")
        try await watchEventually { first.isWaiting }
        let old = try #require(owner.store.logSessions.first)
        owner.actions.switchLogContainer(old.id, name: name)
        try await watchEventually { next.isWaiting }
        let new = try #require(owner.store.logSessions.last)
        #expect(old.id != new.id && old.scope.container.name == "web" && new.scope.container.name == name)
        #expect(old.state == .paused && first.cancelled && old.buffer.lines.last?.text == "old")
        #expect(new.segment == 1 && new.buffer.lines.last?.text == "new" && new.buffer.lines.filter(\.isBoundary).count == 1)
        #expect(await transport.requests.count == 2)
        #expect(await transport.streams.last.map { podQuery($0)["container"] } == name)
        await owner.actions.shutdownAndWait()
    }

    @Test(arguments: [400, 403, 404])
    func unavailableLogsAreInlineStateAndRetainSegment(_ code: Int) async throws {
        let transport = LogTestTransport(stream: { _, _ in throw APIError.http(code: code, resource: "sensitive") })
        let owner = try PodShellTestOwner(transport: transport, logs: LogService { _ in transport })
        owner.actions.openPodLogs(uid: "uid-0", container: "web")
        let expected = LogFailure.classify(APIError.http(code: code, resource: "pods/log"))
        try await watchEventually { owner.store.logSessions.first?.state == .failed(expected) }
        let session = try #require(owner.store.logSessions.first)
        #expect(session.buffer.count == 1 && session.segment == 1)
        #expect(!session.status.contains("sensitive"))
        await owner.actions.shutdownAndWait()
    }

    @Test func detailsErrorsAndMissingServiceAreMeaningfulWithoutSession() async throws {
        let transport = LogTestTransport(data: { _, _ in throw APIError.http(code: 403, resource: "private") })
        let owner = try PodShellTestOwner(transport: transport, logs: LogService { _ in transport })
        owner.actions.openPodLogs(uid: "uid-0", container: "web")
        try await watchEventually { owner.store.podLogDiagnostic != nil }
        #expect(owner.store.podLogDiagnostic == LogFailure.forbidden.diagnostic)
        #expect(owner.store.logSessions.isEmpty && !owner.store.isLoadingPodDetails)
        await owner.actions.shutdownAndWait()
        let absent = try PodShellTestOwner(transport: transport)
        absent.actions.openPodLogs(uid: "uid-0", container: "web")
        #expect(absent.store.podLogDiagnostic != nil && absent.store.logSessions.isEmpty)
        await absent.actions.shutdownAndWait()
    }

    @Test func activeSessionSurvivesRowChangeButScopeChangePausesWithoutRetargeting() async throws {
        let bytes = MemoryByteStream([Data("kept\n".utf8)])
        let transport = LogTestTransport(stream: { _, _ in bytes })
        let owner = try PodShellTestOwner(transport: transport, logs: LogService { _ in transport })
        owner.actions.openPodLogs(uid: "uid-0", container: "web")
        try await watchEventually { bytes.isWaiting }
        let session = try #require(owner.store.logSessions.first)
        try owner.changeRow()
        owner.actions.setListFilter("pod-1")
        #expect(session.state == .following && !bytes.cancelled)
        try owner.actions.selectContext(named: "second")
        try await watchEventually { bytes.cancelled && owner.actions.logTasks.isEmpty }
        #expect(session.state == .paused && session.scope.context.name == "first")
        owner.actions.resumeLog(session.id)
        #expect(session.state == .failed(.unavailable))
        #expect(await transport.requests.count == 1)
        await owner.actions.shutdownAndWait()
    }

    @Test(arguments: [false, true])
    func observedDeletionOrReplacementStopsFollowingWithoutReplay(_ replacement: Bool) async throws {
        let watchBytes = MemoryByteStream()
        let logBytes = MemoryByteStream([Data("retained\n".utf8)])
        let transport = LogTestTransport(
            data: { request, _ in
                request.accept == APIRequest.tableAccept ? try podPage() : try podDetailsData()
            },
            stream: { request, _ in request.path.last == "log" ? logBytes : watchBytes }
        )
        let owner = try PodShellTestOwner(
            transport: transport, watch: WatchService { _ in transport }, logs: LogService { _ in transport }
        )
        defer { owner.actions.shutdown() }
        owner.actions.refreshList()
        try await watchEventually { watchBytes.isWaiting && owner.store.connection == .live }
        owner.actions.openPodLogs(uid: "uid-0", container: "web")
        try await watchEventually { logBytes.isWaiting }
        let session = try #require(owner.store.logSessions.first)
        if replacement {
            let event = String(decoding: try podEvent(id: 0), as: UTF8.self)
                .replacingOccurrences(of: "uid-0", with: "replacement")
            watchBytes.yield(Data(event.utf8))
            try await watchEventually { owner.store.rows.count == 2 }
        }
        watchBytes.yield(try podEvent("DELETED", id: 0))
        try await watchEventually { owner.store.rows.allSatisfy { $0.id != "uid-0" } }
        await Task.yield()
        #expect(session.state == .failed(replacement ? .replaced : .deleted))
        #expect(!session.status.contains("404"))
        try await watchEventually { owner.actions.logTasks.isEmpty }
        #expect(logBytes.cancelled && session.segment == 1 && session.buffer.lines.last?.text == "retained")
        #expect(session.scope.subject.uid == "uid-0")
        #expect(await transport.streams.filter { $0.path.last == "log" }.count == 1)
        await owner.actions.shutdownAndWait()
        #expect(watchBytes.cancelled)
    }

    @Test func incompleteRelistCannotDeclareAnActiveLogDeleted() async throws {
        let bytes = MemoryByteStream()
        let transport = LogTestTransport(stream: { _, _ in bytes })
        let owner = try PodShellTestOwner(transport: transport, logs: LogService { _ in transport })
        defer { owner.actions.shutdown() }
        owner.actions.openPodLogs(uid: "uid-0", container: "web")
        try await watchEventually { bytes.isWaiting }
        let session = try #require(owner.store.logSessions.first)
        owner.actions.applyListUpdate(.init(kind: .pods, rows: [], columns: nil, connection: .connecting))
        #expect(session.state == .following && !bytes.cancelled)
        try owner.install(ids: [0])
        #expect(session.state == .following && !bytes.cancelled)
        await owner.actions.shutdownAndWait()
    }
}
