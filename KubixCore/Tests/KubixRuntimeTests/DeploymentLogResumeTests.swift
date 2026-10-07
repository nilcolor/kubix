import Foundation
@testable import KubixCore
import KubixRuntime
import Testing

/// What happens to an aggregated tab after it is running. Resume is the only way its pod set changes,
/// which is the limitation the design accepts, so these cover that it actually re-resolves — and that
/// it still refuses a deployment that is no longer the one the tab was opened against.
@Suite @MainActor struct DeploymentLogResumeTests {
    private func owner(
        deployment: ScriptedDeployment, pods: ScriptedDeploymentPods
    ) throws -> PodShellTestOwner {
        let transport = LogTestTransport(stream: { _, _ in MemoryByteStream([Data("line\n".utf8)]) })
        let owner = try PodShellTestOwner(
            transport: transport, logs: LogService { _ in transport },
            deployments: deployment, deploymentPods: pods
        )
        owner.actions.clearList(.deployments)
        try owner.install()
        return owner
    }

    private func podSet(_ names: [String]) -> [DeploymentPod] {
        names.enumerated().map { index, name in
            DeploymentPod(name: name, uid: "pod-uid-\(name)", created: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        }
    }

    private func opened(
        _ owner: PodShellTestOwner, expecting count: Int
    ) async throws -> LogSession {
        owner.actions.openDeploymentLogs(uid: "uid-0")
        try await watchEventually { owner.store.logSessions.first?.followingCount == count }
        return try #require(owner.store.logSessions.first)
    }

    /// The point of Resume on a deployment: a tab that went quiet through a rollout picks up the
    /// replicas that exist now, keeping the lines it already has under a new segment boundary.
    @Test func resumeReResolvesThePodSetAndKeepsTheBuffer() async throws {
        let deployment = ScriptedDeployment(.success(try deploymentDetails()))
        let pods = ScriptedDeploymentPods(.success(podSet(["old-a", "old-b"])))
        let owner = try owner(deployment: deployment, pods: pods)
        defer { owner.actions.shutdown() }
        let session = try await opened(owner, expecting: 2)
        try await watchEventually { session.buffer.count >= 3 }
        let before = session.buffer.count

        await pods.answer(.success(podSet(["new-a", "new-b", "new-c"])))
        owner.actions.resumeLog(session.id)
        try await watchEventually { session.followingCount == 3 }
        #expect(session.sources.map(\.target.pod) == ["new-c", "new-b", "new-a"])
        #expect(session.segment == 2)
        #expect(session.buffer.count > before)
        #expect(owner.store.logSessions.count == 1)
        // The ring grew with the set rather than being rebuilt at the old size.
        #expect(session.buffer.maximumLines == LogBuffer(sources: 3).maximumLines)
        await owner.actions.shutdownAndWait()
    }

    /// A deployment recreated under the same name is a different object, and this tab follows the one
    /// it was opened against.
    @Test func resumeRejectsAReplacedDeploymentAndTailsNothing() async throws {
        let deployment = ScriptedDeployment(.success(try deploymentDetails()))
        let pods = ScriptedDeploymentPods(.success(podSet(["alpha"])))
        let owner = try owner(deployment: deployment, pods: pods)
        defer { owner.actions.shutdown() }
        let session = try await opened(owner, expecting: 1)

        await deployment.answer(.success(try deploymentDetails(uid: "recreated")))
        owner.actions.resumeLog(session.id)
        try await watchEventually { session.state == .failed(.replaced) }
        #expect(session.sources.allSatisfy { $0.state == .failed(.replaced) })
        #expect(session.segment == 1)
        await owner.actions.shutdownAndWait()
    }

    /// A deployment that scaled to zero while the tab was open reports it rather than keeping the
    /// pods it used to have.
    @Test func resumeOnADeploymentWithNoPodsLeftReportsIt() async throws {
        let deployment = ScriptedDeployment(.success(try deploymentDetails()))
        let pods = ScriptedDeploymentPods(.success(podSet(["alpha"])))
        let owner = try owner(deployment: deployment, pods: pods)
        defer { owner.actions.shutdown() }
        let session = try await opened(owner, expecting: 1)
        await pods.answer(.success([]))
        owner.actions.resumeLog(session.id)
        try await watchEventually { session.state == .failed(.noPods) }
        #expect(session.sources.isEmpty)
        await owner.actions.shutdownAndWait()
    }

    @Test func pauseStopsEveryStreamAndCloseClearsTheTab() async throws {
        let deployment = ScriptedDeployment(.success(try deploymentDetails()))
        let pods = ScriptedDeploymentPods(.success(podSet(["alpha", "beta"])))
        let owner = try owner(deployment: deployment, pods: pods)
        defer { owner.actions.shutdown() }
        let session = try await opened(owner, expecting: 2)

        owner.actions.pauseLog(session.id)
        try await watchEventually { owner.actions.logTasks.isEmpty }
        #expect(session.state == .paused)

        owner.actions.closeLog(session.id)
        #expect(owner.store.logSessions.isEmpty && owner.store.openSessions.isEmpty)
        #expect(session.sources.isEmpty && session.buffer.count == 0)
        #expect(owner.actions.logAttempts.isEmpty && owner.actions.deploymentLogAttempts.isEmpty)
        await owner.actions.shutdownAndWait()
    }

    /// A container switch is a second tab, never a rebinding: the lines already collected belong to
    /// the container that logged them.
    @Test func switchingContainerOpensASecondTabForTheSameDeployment() async throws {
        let deployment = ScriptedDeployment(.success(try deploymentDetails(containers: ["server", "proxy"])))
        let pods = ScriptedDeploymentPods(.success(podSet(["alpha"])))
        let owner = try owner(deployment: deployment, pods: pods)
        defer { owner.actions.shutdown() }
        owner.actions.openDeploymentLogs(uid: "uid-0", container: "server")
        try await watchEventually { owner.store.logSessions.first?.followingCount == 1 }
        let first = try #require(owner.store.logSessions.first)

        owner.actions.switchLogContainer(first.id, name: "proxy")
        try await watchEventually { owner.store.logSessions.count == 2 }
        let second = try #require(owner.store.logSessions.last)
        try await watchEventually { second.followingCount == 1 }
        #expect(second.id != first.id)
        #expect(second.scope.container.name == "proxy" && first.scope.container.name == "server")
        #expect(second.scope.subject == first.scope.subject)
        #expect(first.state == .paused)

        // Asking again focuses the tab that exists rather than opening a third.
        owner.actions.openSessionForContainer(.logs(second.id), container: "server")
        #expect(owner.store.logSessions.count == 2)
        #expect(owner.store.selectedSession == .logs(first.id))
        #expect(owner.actions.hasOpenSession(.logs(first.id), container: "proxy"))
        await owner.actions.shutdownAndWait()
    }

    /// A namespace change is a scope change: the tab's lines describe somewhere the user is no longer
    /// looking, so it pauses rather than following on.
    @Test func aScopeChangePausesAnAggregatedTab() async throws {
        let deployment = ScriptedDeployment(.success(try deploymentDetails()))
        let pods = ScriptedDeploymentPods(.success(podSet(["alpha", "beta"])))
        let owner = try owner(deployment: deployment, pods: pods)
        defer { owner.actions.shutdown() }
        let session = try await opened(owner, expecting: 2)
        try owner.actions.selectNamespace("other")
        try await watchEventually { session.state == .paused }
        // And Resume from the wrong scope says so rather than reaching across it.
        owner.actions.resumeLog(session.id)
        try await watchEventually { session.state == .failed(.unavailable) }
        await owner.actions.shutdownAndWait()
    }

    /// Quit must join every stream, not just the first: a source left running would outlive the app's
    /// own shutdown.
    @Test func shutdownJoinsEverySourceTask() async throws {
        let deployment = ScriptedDeployment(.success(try deploymentDetails()))
        let pods = ScriptedDeploymentPods(.success(podSet(["alpha", "beta", "gamma"])))
        let owner = try owner(deployment: deployment, pods: pods)
        let session = try await opened(owner, expecting: 3)
        #expect(owner.actions.logAttempts.count == 3)
        await owner.actions.shutdownAndWait()
        #expect(owner.actions.logTasks.isEmpty)
        #expect(session.followingCount == 3 || session.state == .paused)
    }
}
