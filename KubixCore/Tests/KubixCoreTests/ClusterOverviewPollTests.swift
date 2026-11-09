import Foundation
@testable import KubixCore
import Testing

/// Answers every section with fixed counts unless told to fail it; optionally holds every call at a gate.
actor ScriptedOverview: ClusterOverviewListing {
    static let nodeCounts = NodeCounts(total: 3, ready: 2)
    static let workloadCounts = WorkloadCounts(total: 4, running: 3, pending: 1)

    private var failures: [OverviewSection: any Error] = [:]
    private(set) var calls: [OverviewSection] = []
    private let gate: AppTestGate?

    init(gate: AppTestGate? = nil) { self.gate = gate }

    func fail(_ section: OverviewSection, with error: (any Error)?) { failures[section] = error }
    func count(_ section: OverviewSection) -> Int { calls.filter { $0 == section }.count }

    private func answer(_ section: OverviewSection) async throws {
        calls.append(section)
        if let gate { try await gate.wait() }
        if let failure = failures[section] { throw failure }
    }

    func nodes(context: ResolvedContext) async throws -> NodeCounts {
        try await answer(.nodes)
        return Self.nodeCounts
    }

    func warningEvents(context: ResolvedContext) async throws -> Int {
        try await answer(.warningEvents)
        return 7
    }

    func workloads(_ kind: WorkloadKind, context: ResolvedContext) async throws -> WorkloadCounts {
        try await answer(.workload(kind))
        return Self.workloadCounts
    }
}

@Suite @MainActor struct ClusterOverviewPollTests {
    private func owner(
        _ overview: ScriptedOverview, clock: TestClock = TestClock()
    ) async throws -> (store: AppStore, actions: AppActions) {
        let probe = ClusterTestProbe()
        await probe.open()
        let store = AppStore(contexts: [try appContext()])
        let actions = AppActions(
            store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces(),
            lists: PodActionProbe(), probe: probe, namespaces: NamespaceTestLister(names: ["alpha"]),
            overview: overview, overviewInterval: .milliseconds(10), monotonicNow: { clock.now }
        )
        return (store, actions)
    }

    private func connected(_ overview: ScriptedOverview, clock: TestClock = TestClock()) async throws -> (AppStore, AppActions) {
        let (store, actions) = try await owner(overview, clock: clock)
        actions.connect(contextNamed: "first")
        try await appEventually { store.clusters[0].overview.nodes.value != nil }
        return (store, actions)
    }

    @Test func connectingOnTheDashboardFillsEverySectionAndKeepsPolling() async throws {
        let overview = ScriptedOverview()
        let (store, actions) = try await owner(overview)
        #expect(store.sidebarSelection == .cluster("first"))
        #expect(store.clusters[0].overview == ClusterOverview())
        actions.connect(contextNamed: "first")
        try await appEventually {
            let result = store.clusters[0].overview
            return result.nodes == .value(ScriptedOverview.nodeCounts) && result.warningEvents == .value(7)
                && WorkloadKind.allCases.allSatisfy { result.workload($0) == .value(ScriptedOverview.workloadCounts) }
        }
        try await appEventually { await overview.count(.nodes) >= 3 }
        await actions.shutdownAndWait()
    }

    @Test func nothingIsAskedBeforeConnect() async throws {
        let overview = ScriptedOverview()
        let (_, actions) = try await owner(overview)
        actions.selectSidebar(.cluster("first"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await overview.calls.isEmpty)
        await actions.shutdownAndWait()
    }

    /// The poll runs only while the pane is on screen; landing on it again asks at once.
    @Test func aListSelectionStopsThePollAndReturningRefreshesImmediately() async throws {
        let overview = ScriptedOverview()
        let (store, actions) = try await connected(overview)
        actions.selectSidebar(.list("first", .pods))
        try await Task.sleep(for: .milliseconds(30))
        let paused = await overview.count(.nodes)
        try await Task.sleep(for: .milliseconds(60))
        #expect(await overview.count(.nodes) == paused)
        // The last numbers stay, so the pane does not drop back to skeletons on the way back.
        #expect(store.clusters[0].overview.nodes == .value(ScriptedOverview.nodeCounts))
        actions.selectSidebar(.cluster("first"))
        try await appEventually { await overview.count(.nodes) > paused }
        await actions.shutdownAndWait()
    }

    @Test func disconnectingClearsTheNumbersAndStopsAsking() async throws {
        let overview = ScriptedOverview()
        let (store, actions) = try await connected(overview)
        actions.disconnect(contextNamed: "first")
        #expect(store.clusters[0].overview == ClusterOverview())
        try await Task.sleep(for: .milliseconds(30))
        let stopped = await overview.count(.nodes)
        try await Task.sleep(for: .milliseconds(60))
        #expect(await overview.count(.nodes) == stopped)
        #expect(store.clusters[0].overview == ClusterOverview())
        await actions.shutdownAndWait()
    }

    /// RBAC that denies one kind is a configuration, not a fault: that row says so and is not asked
    /// again, and every other section keeps updating.
    @Test func aDeniedSectionIsMarkedAndNotAskedAgainUntilReconnect() async throws {
        let overview = ScriptedOverview()
        await overview.fail(.workload(.daemonSets), with: APIError.http(code: 403, resource: "daemonsets"))
        let (store, actions) = try await connected(overview)
        try await appEventually { store.clusters[0].overview.workload(.daemonSets) == .notPermitted }
        let asked = await overview.count(.workload(.daemonSets))
        try await appEventually { await overview.count(.nodes) >= 4 }
        #expect(await overview.count(.workload(.daemonSets)) == asked)
        #expect(store.clusters[0].overview.workload(.jobs) == .value(ScriptedOverview.workloadCounts))

        actions.disconnect(contextNamed: "first")
        await overview.fail(.workload(.daemonSets), with: nil)
        actions.connect(contextNamed: "first")
        try await appEventually { store.clusters[0].overview.workload(.daemonSets).value != nil }
        await actions.shutdownAndWait()
    }

    @Test func aSectionTooLargeToCountIsNotDownloadedAgain() async throws {
        let overview = ScriptedOverview()
        await overview.fail(.workload(.pods), with: ClusterOverviewFailure.tooManyBytes)
        let (store, actions) = try await connected(overview)
        try await appEventually { store.clusters[0].overview.workload(.pods) == .tooLarge }
        try await appEventually { await overview.count(.nodes) >= 4 }
        #expect(await overview.count(.workload(.pods)) == 1)
        await actions.shutdownAndWait()
    }

    /// Every tick would otherwise re-run the credential plugin. Selecting the pane again is the retry.
    @Test(arguments: [PollStop.unauthorized, .credentials])
    func credentialFailuresStopThePollUntilThePaneIsSelectedAgain(_ stop: PollStop) async throws {
        let overview = ScriptedOverview()
        let (store, actions) = try await connected(overview)
        await overview.fail(.nodes, with: stop.error)
        try await appEventually { store.clusters[0].overview.nodes == .failed }
        let stopped = await overview.count(.nodes)
        try await Task.sleep(for: .milliseconds(60))
        #expect(await overview.count(.nodes) == stopped)

        await overview.fail(.nodes, with: nil)
        actions.selectSidebar(.list("first", .pods))
        actions.selectSidebar(.cluster("first"))
        try await appEventually { store.clusters[0].overview.nodes.value != nil }
        await actions.shutdownAndWait()
    }

    @Test func transientFailuresKeepTheLastNumbersUntilTheyAreStale() async throws {
        let clock = TestClock()
        let overview = ScriptedOverview()
        let (store, actions) = try await connected(overview, clock: clock)
        await overview.fail(.warningEvents, with: APIError.http(code: 503, resource: "events"))
        let failing = await overview.count(.warningEvents)
        try await appEventually { await overview.count(.warningEvents) >= failing + 2 }
        #expect(store.clusters[0].overview.warningEvents == .value(7))

        clock.advance(AppActions.overviewStaleAfter + 1)
        try await appEventually { store.clusters[0].overview.warningEvents == .failed }
        // Still polling: a restarting apiserver is worth asking again.
        await overview.fail(.warningEvents, with: nil)
        try await appEventually { store.clusters[0].overview.warningEvents == .value(7) }
        await actions.shutdownAndWait()
    }

    @Test func anAnswerForADisconnectedClusterIsDiscarded() async throws {
        let gate = AppTestGate()
        let overview = ScriptedOverview(gate: gate)
        let (store, actions) = try await owner(overview)
        actions.connect(contextNamed: "first")
        try await appEventually { await overview.calls.count == OverviewSection.all.count }
        actions.disconnect(contextNamed: "first")
        await gate.open()
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.clusters[0].overview == ClusterOverview())
        await actions.shutdownAndWait()
    }

    @Test func shutdownJoinsAnInFlightTick() async throws {
        let gate = AppTestGate()
        let overview = ScriptedOverview(gate: gate)
        let (store, actions) = try await owner(overview)
        actions.connect(contextNamed: "first")
        try await appEventually { await overview.calls.count == OverviewSection.all.count }
        await actions.shutdownAndWait()
        #expect(store.clusters[0].overview == ClusterOverview())
        #expect(await gate.count == 0)
    }
}
