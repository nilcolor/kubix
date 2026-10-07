import Foundation
@testable import KubixCore
import KubixRuntime
import Testing

actor ScriptedDeployment: DeploymentDetailsProviding {
    private var result: Result<DeploymentDetails, any Error>
    private(set) var requests: [String] = []
    private let gate: TestGate?

    init(_ result: Result<DeploymentDetails, any Error>, gate: TestGate? = nil) {
        self.result = result
        self.gate = gate
    }

    func details(context: ResolvedContext, namespace: String, name: String, uid: String) async throws -> DeploymentDetails {
        requests.append(name)
        if let gate { try await gate.wait() }
        return try result.get()
    }

    func answer(_ result: Result<DeploymentDetails, any Error>) { self.result = result }
}

actor ScriptedDeploymentPods: DeploymentPodListing {
    private var result: Result<[DeploymentPod], any Error>
    private(set) var selectors: [String] = []

    init(_ result: Result<[DeploymentPod], any Error>) { self.result = result }

    func pods(context: ResolvedContext, namespace: String, selector: LabelSelector) async throws -> [DeploymentPod] {
        selectors.append(selector.query)
        return try result.get()
    }

    func answer(_ result: Result<[DeploymentPod], any Error>) { self.result = result }
}

func deploymentDetails(
    uid: String = "uid-0", name: String = "pod-0", namespace: String = "team",
    selector: [String: String] = ["app": "web"], containers: [String] = ["server"],
    annotation: String? = nil
) throws -> DeploymentDetails {
    try JSONDecoder().decode(DeploymentDetails.self, from: try deploymentDetailsData(
        uid: uid, name: name, namespace: namespace, selector: selector,
        containers: containers, initContainers: nil, annotation: annotation
    ))
}

/// Opening a deployment's logs. The row the user clicked is a deployment, so two reads stand between
/// the click and the first line, and every guard the pod path has must hold across both of them.
@Suite @MainActor struct DeploymentLogActionTests {
    private func owner(
        deployment: ScriptedDeployment, pods: ScriptedDeploymentPods,
        streams: @escaping @Sendable (APIRequest, Int) async throws -> any HTTPByteStream = { _, _ in
            MemoryByteStream([Data("line\n".utf8)])
        }
    ) throws -> PodShellTestOwner {
        let transport = LogTestTransport(stream: streams)
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

    @Test func oneTabFollowsEveryPodTheSelectorFinds() async throws {
        let deployment = ScriptedDeployment(.success(try deploymentDetails()))
        let pods = ScriptedDeploymentPods(.success(podSet(["alpha", "beta", "gamma"])))
        let owner = try owner(deployment: deployment, pods: pods)
        defer { owner.actions.shutdown() }

        owner.actions.openDeploymentLogs(uid: "uid-0")
        try await watchEventually { owner.store.logSessions.first?.followingCount == 3 }
        let session = try #require(owner.store.logSessions.first)
        #expect(owner.store.logSessions.count == 1)
        #expect(session.scope.subject == .deployment(name: "pod-0", uid: "uid-0"))
        #expect(session.scope.container.name == "server")
        // Newest first, which is what a capped set would keep.
        #expect(session.sources.map(\.target.pod) == ["gamma", "beta", "alpha"])
        #expect(session.resolved == nil)
        #expect(await pods.selectors == ["app=web"])
        #expect(await deployment.requests == ["pod-0"])
        #expect(owner.store.selectedSession == .logs(session.id))
        await owner.actions.shutdownAndWait()
    }

    /// A single-container template opens with no menu, as a single-container pod does.
    @Test func oneContainerOpensWithoutAskingAndSeveralAsk() async throws {
        let one = ScriptedDeployment(.success(try deploymentDetails()))
        let single = try owner(deployment: one, pods: ScriptedDeploymentPods(.success(podSet(["alpha"]))))
        defer { single.actions.shutdown() }
        single.actions.openDeploymentLogs(uid: "uid-0")
        try await watchEventually { single.store.logSessions.count == 1 }
        #expect(single.store.containerPicker == nil)
        await single.actions.shutdownAndWait()

        let many = ScriptedDeployment(.success(try deploymentDetails(containers: ["server", "proxy"], annotation: "proxy")))
        let asking = try owner(deployment: many, pods: ScriptedDeploymentPods(.success(podSet(["alpha"]))))
        defer { asking.actions.shutdown() }
        asking.actions.openDeploymentLogs(uid: "uid-0")
        try await watchEventually { asking.store.containerPicker != nil }
        let picker = try #require(asking.store.containerPicker)
        #expect(picker.pod == "deploy/pod-0")
        #expect(picker.containers == ["server", "proxy"])
        #expect(picker.defaultContainer == "proxy")
        // A template has no state across replicas, so the menu claims none.
        #expect(picker.items.allSatisfy { $0.state == nil })
        #expect(picker.items.map(\.role) == ["Container", "Default container"])
        #expect(asking.store.logSessions.isEmpty)

        asking.actions.confirmDeploymentLogs(selectionID: picker.id, container: "proxy")
        try await watchEventually { asking.store.logSessions.first?.followingCount == 1 }
        #expect(asking.store.logSessions.first?.scope.container.name == "proxy")
        #expect(asking.store.containerPicker == nil)
        await asking.actions.shutdownAndWait()
    }

    /// A deployment that has scaled to zero gets a tab that says so, rather than silence or a
    /// borrowed "deleted" that would describe the deployment instead of its pods.
    @Test func aDeploymentWithNoPodsReportsItAndTailsNothing() async throws {
        let deployment = ScriptedDeployment(.success(try deploymentDetails()))
        let owner = try owner(deployment: deployment, pods: ScriptedDeploymentPods(.success([])))
        defer { owner.actions.shutdown() }
        owner.actions.openDeploymentLogs(uid: "uid-0")
        try await watchEventually { owner.store.logSessions.first?.state == .failed(.noPods) }
        let session = try #require(owner.store.logSessions.first)
        #expect(session.sources.isEmpty && session.segment == 0)
        #expect(session.status == "This deployment has no pods to tail. Resume once it has some.")
        await owner.actions.shutdownAndWait()
    }

    /// Above the ceiling the tab keeps the newest and says how many it found, rather than tailing a
    /// subset and looking like it followed the lot.
    @Test func aboveTheCeilingTheNewestAreKeptAndTheShortfallIsReported() async throws {
        let deployment = ScriptedDeployment(.success(try deploymentDetails()))
        let names = (0..<(LogSession.maximumSources + 7)).map { "pod-\($0)" }
        let owner = try owner(deployment: deployment, pods: ScriptedDeploymentPods(.success(podSet(names))))
        defer { owner.actions.shutdown() }
        owner.actions.openDeploymentLogs(uid: "uid-0")
        try await watchEventually { owner.store.logSessions.first?.sources.count == LogSession.maximumSources }
        let session = try #require(owner.store.logSessions.first)
        #expect(session.resolved == names.count)
        #expect(session.sources.first?.target.pod == names.last)
        try await watchEventually { session.state == .following }
        #expect(session.status.contains("of \(names.count) found"))
        await owner.actions.shutdownAndWait()
    }

    /// A selector this cannot address exactly reports why, in the deployment's own words, and opens
    /// no tab at all — there is nothing for one to follow.
    @Test func aRefusedSelectorReportsItsOwnReasonAndOpensNothing() async throws {
        let deployment = ScriptedDeployment(.failure(DeploymentDetailsError.setBasedSelector))
        let owner = try owner(deployment: deployment, pods: ScriptedDeploymentPods(.success([])))
        defer { owner.actions.shutdown() }
        owner.actions.openDeploymentLogs(uid: "uid-0")
        try await watchEventually { owner.store.podLogDiagnostic != nil }
        #expect(owner.store.podLogDiagnostic?.contains("matchExpressions") == true)
        #expect(owner.store.logSessions.isEmpty)
        #expect(owner.store.isLoadingPodDetails == false && owner.store.pendingContainerPurpose == nil)
        await owner.actions.shutdownAndWait()
    }

    /// Name-addressed endpoints have no UID precondition, so a deployment recreated under the same
    /// name between the click and the read must not be adopted.
    @Test func aReplacedDeploymentIsRejectedRatherThanFollowed() async throws {
        let deployment = ScriptedDeployment(.success(try deploymentDetails(uid: "other-uid")))
        let owner = try owner(deployment: deployment, pods: ScriptedDeploymentPods(.success(podSet(["alpha"]))))
        defer { owner.actions.shutdown() }
        owner.actions.openDeploymentLogs(uid: "uid-0")
        try await watchEventually { owner.store.podLogDiagnostic != nil }
        #expect(owner.store.logSessions.isEmpty)
        await owner.actions.shutdownAndWait()
    }

    /// The same guard the pod path has: a row that changed under a pending request cannot open a tab
    /// bound to what the user clicked, because it is no longer what they clicked.
    @Test func aSupersededSelectionCannotOpenATab() async throws {
        let gate = TestGate()
        let deployment = ScriptedDeployment(.success(try deploymentDetails()), gate: gate)
        let owner = try owner(deployment: deployment, pods: ScriptedDeploymentPods(.success(podSet(["alpha"]))))
        defer { owner.actions.shutdown() }
        owner.actions.openDeploymentLogs(uid: "uid-0")
        try await watchEventually { await deployment.requests.count == 1 }
        try owner.changeRow()
        await gate.open()
        try await watchEventually { owner.actions.podDetailTasks.isEmpty }
        #expect(owner.store.logSessions.isEmpty)
        await owner.actions.shutdownAndWait()
    }

    /// Only the selected kind's action may run: the pane hides the other one, and the action refuses
    /// regardless of what the pane renders.
    @Test func thePodsSlotRefusesTheDeploymentAction() async throws {
        let deployment = ScriptedDeployment(.success(try deploymentDetails()))
        let owner = try owner(deployment: deployment, pods: ScriptedDeploymentPods(.success(podSet(["alpha"]))))
        defer { owner.actions.shutdown() }
        owner.actions.clearList(.pods)
        try owner.install()
        owner.actions.openDeploymentLogs(uid: "uid-0")
        #expect(await deployment.requests.isEmpty)
        #expect(owner.store.logSessions.isEmpty)
        await owner.actions.shutdownAndWait()
    }
}
