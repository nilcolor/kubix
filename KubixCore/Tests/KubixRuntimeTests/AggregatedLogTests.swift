import Foundation
@testable import KubixCore
import KubixRuntime
import Testing

/// Several streams in one tab, through the real `LogService`. The point of the shape is that one pod
/// going wrong is that pod's problem: a rollout always has a replica that is not ready yet, and a tab
/// that failed whenever any of its pods did would be unusable on exactly the workloads it is for.
@Suite @MainActor struct AggregatedLogTests {
    private func owner(
        _ streams: [String: @Sendable () throws -> any HTTPByteStream]
    ) throws -> (PodShellTestOwner, LogTestTransport) {
        let transport = LogTestTransport(stream: { request, _ in
            guard request.path.count == 7, let make = streams[request.path[5]] else {
                throw APIError.http(code: 404, resource: "pods/log")
            }
            return try make()
        })
        return (try PodShellTestOwner(transport: transport, logs: LogService { _ in transport }), transport)
    }

    private func session(_ owner: PodShellTestOwner, pods: [String]) throws -> LogSession {
        let context = try #require(owner.store.contexts.first)
        let container = PodDetails.Container(name: "server", kind: .regular, state: .declared)
        let sources = try pods.map { name in
            LogSource(target: try LogTarget(
                context: context, namespace: "team", pod: name, uid: "uid-\(name)", container: container
            ))
        }
        return owner.actions.install(LogSession(
            scope: LogScope(
                context: context, namespace: "team",
                subject: .deployment(name: "web", uid: "deploy-uid"), container: container
            ),
            containers: [container], sources: sources
        ))
    }

    @Test func oneUnreadyPodDoesNotFailTheTabAndItsLinesCarryTheirPod() async throws {
        let (owner, transport) = try owner([
            "alpha": { MemoryByteStream([Data("alpha one\n".utf8)]) },
            // A pod that exists but has no logs yet answers 400, which is most of a rollout.
            "beta": { throw APIError.http(code: 400, resource: "pods/log") },
            "gamma": { MemoryByteStream([Data("gamma one\n".utf8)]) },
        ])
        defer { owner.actions.shutdown() }
        let session = try session(owner, pods: ["alpha", "beta", "gamma"])
        owner.actions.startLog(session)
        try await watchEventually { session.followingCount == 2 }
        try await watchEventually { session.buffer.lines.count == 3 }

        #expect(session.state == .following)
        #expect(session.sources.first { $0.target.pod == "beta" }?.state == .failed(.notReady))
        #expect(session.status.hasPrefix("Following 2 of 3 pods. "))
        // The label is beside the text, not inside it, so a filter still matches what was logged.
        let lines = session.buffer.lines.filter { !$0.isBoundary }
        #expect(Set(lines.compactMap(\.source)) == ["alpha", "gamma"])
        #expect(Set(lines.map(\.text)) == ["alpha one", "gamma one"])
        #expect(await transport.streams.count == 3)
        // Each stream asked for a share of the tail rather than 200 lines of its own.
        let tails = await transport.streams.compactMap { $0.query.first { $0.name == "tailLines" }?.value }
        #expect(Set(tails) == ["333"])
        await owner.actions.shutdownAndWait()
    }

    /// The tab reports a failure only when nothing ever opened — and then it is the real reason, not
    /// a generic one, because every stream hit the same wall.
    @Test func aTabFailsOnlyWhenNoStreamEverOpened() async throws {
        let (owner, _) = try owner([
            "alpha": { throw APIError.http(code: 403, resource: "pods/log") },
            "beta": { throw APIError.http(code: 403, resource: "pods/log") },
        ])
        defer { owner.actions.shutdown() }
        let session = try session(owner, pods: ["alpha", "beta"])
        owner.actions.startLog(session)
        try await watchEventually { session.state == .failed(.forbidden) }
        #expect(session.followingCount == 0)
        #expect(session.status.contains("get-pods/log permission"))
        await owner.actions.shutdownAndWait()
    }

    /// Clean endings do not get overwritten by a pod that stopped badly, and vice versa: the tab
    /// reports the worse news of the two so a mid-stream death is never hidden behind an EOF.
    @Test func everyStreamEndingCleanlyIsCompletedAndOneDyingIsInterrupted() async throws {
        let (clean, _) = try owner([
            "alpha": { MemoryByteStream([Data("a\n".utf8)], finished: true) },
            "beta": { MemoryByteStream([Data("b\n".utf8)], finished: true) },
        ])
        defer { clean.actions.shutdown() }
        let completed = try session(clean, pods: ["alpha", "beta"])
        clean.actions.startLog(completed)
        try await watchEventually { completed.state == .completed }
        await clean.actions.shutdownAndWait()
    }

    /// Pause stops every stream at once, and the partial line each was holding still lands: those
    /// bytes were logged before the pause.
    @Test func pauseStopsEveryStreamAndKeepsWhatHadAlreadyArrived() async throws {
        let alpha = MemoryByteStream([Data("alpha one\nalpha part".utf8)])
        let beta = MemoryByteStream([Data("beta one\nbeta part".utf8)])
        let (owner, _) = try owner(["alpha": { alpha }, "beta": { beta }])
        defer { owner.actions.shutdown() }
        let session = try session(owner, pods: ["alpha", "beta"])
        owner.actions.startLog(session)
        try await watchEventually { session.followingCount == 2 && session.buffer.lines.count == 3 }
        owner.actions.pauseLog(session.id)
        try await watchEventually { owner.actions.logTasks.isEmpty }
        #expect(session.state == .paused && alpha.cancelled && beta.cancelled)
        let texts = Set(session.buffer.lines.map(\.text))
        #expect(texts.contains("alpha part") && texts.contains("beta part"))
        await owner.actions.shutdownAndWait()
    }
}
