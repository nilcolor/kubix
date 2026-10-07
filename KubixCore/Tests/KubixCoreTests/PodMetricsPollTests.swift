import Foundation
@testable import KubixCore
import Testing

/// A metrics API answering from a script: each call takes the next result, and the last repeats.
actor ScriptedMetrics: PodMetricsListing {
    private var script: [Result<[PodUsage], any Error>]
    private(set) var calls: [String] = []
    private var gate: AppTestGate?

    init(_ script: [Result<[PodUsage], any Error>], gate: AppTestGate? = nil) {
        self.script = script
        self.gate = gate
    }

    func podMetrics(context: ResolvedContext, namespace: String) async throws -> [PodUsage] {
        calls.append(namespace)
        if let gate { try await gate.wait() }
        let next = script.count > 1 ? script.removeFirst() : script[0]
        return try next.get()
    }

    func answer(_ script: [Result<[PodUsage], any Error>]) { self.script = script }
}

enum PollStop: Sendable, CustomTestStringConvertible {
    case unauthorized, credentials

    /// A credential plugin failing is not an `APIError` at all; that is how it reaches the poll.
    struct PluginFailed: Error {}

    var error: any Error {
        switch self {
        case .unauthorized: APIError.credentialsExhausted(.http(code: 401, resource: "pods"))
        case .credentials: PluginFailed()
        }
    }

    var testDescription: String { self == .unauthorized ? "401 after refresh" : "plugin failure" }
}

/// A clock the test moves, for the staleness bound.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private let web = PodUsage(
    name: "web", cpuNanocores: 12_000_000, memoryBytes: 134_217_728,
    timestamp: Date(timeIntervalSince1970: 2_000_000_000), window: 15
)

@Suite @MainActor struct PodMetricsPollTests {
    private func owner(
        _ metrics: ScriptedMetrics, clock: TestClock = TestClock()
    ) throws -> (store: AppStore, actions: AppActions, pods: PodActionProbe) {
        let store = AppStore(contexts: [try appContext()])
        let pods = PodActionProbe()
        let actions = AppActions(
            store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces(),
            lists: pods, metrics: metrics, metricsInterval: .milliseconds(10), monotonicNow: { clock.now }
        )
        return (store, actions, pods)
    }

    @Test func aSampleMakesTheClusterServeUsageAndThePodsTableShowIt() async throws {
        let metrics = ScriptedMetrics([.success([web])])
        let (store, actions, _) = try owner(metrics)
        actions.refreshList()
        try await appEventually { store.clusters[0].metrics == .available && store.podMetrics?["web"] == web }
        #expect(store.listTable.columns.contains { $0.kind == .cpu })
        // It keeps polling while the watch runs.
        try await appEventually { await metrics.calls.count >= 3 }
        #expect(await Set(metrics.calls) == [store.selectedNamespace])
        await actions.shutdownAndWait()
    }

    /// No metrics-server: asking again will not change that, so the cluster is not asked again,
    /// even for the next namespace, until it is reconnected.
    @Test func aClusterWithoutTheMetricsAPIIsNotAskedAgain() async throws {
        let metrics = ScriptedMetrics([.failure(APIError.http(code: 404, resource: "pods"))])
        let (store, actions, _) = try owner(metrics)
        actions.refreshList()
        try await appEventually { store.clusters[0].metrics == .unavailable }
        try await Task.sleep(for: .milliseconds(60))
        #expect(await metrics.calls.count == 1)
        #expect(!store.listTable.columns.contains { $0.kind == .cpu })
        actions.refreshList()
        try await Task.sleep(for: .milliseconds(60))
        #expect(await metrics.calls.count == 1)
        await actions.shutdownAndWait()
    }

    /// A credential that needs the user must not be retried on a timer: every poll would re-run the
    /// plugin. The poll stops and its numbers go, until the watch's explicit Retry restarts it.
    @Test(arguments: [
        PollStop.unauthorized, .credentials,
    ])
    func credentialFailuresStopThePollInsteadOfRerunningThePlugin(_ stop: PollStop) async throws {
        let metrics = ScriptedMetrics([.success([web]), .failure(stop.error)])
        let (store, actions, _) = try owner(metrics)
        actions.refreshList()
        try await appEventually { await metrics.calls.count == 2 }
        try await appEventually { store.podMetrics == [:] }
        try await Task.sleep(for: .milliseconds(60))
        #expect(await metrics.calls.count == 2)
        #expect(store.clusters[0].metrics == .available)
        // The explicit Retry — any refresh of the watch — starts the poll again.
        actions.refreshList()
        try await appEventually { await metrics.calls.count == 3 }
        await actions.shutdownAndWait()
    }

    @Test func onlyFailuresThatCanClearByThemselvesAreRetried() {
        #expect(AppActions.isWorthRetrying(APIError.http(code: 503, resource: "pods")))
        #expect(AppActions.isWorthRetrying(APIError.http(code: 429, resource: "pods")))
        #expect(AppActions.isWorthRetrying(APIError.transport(.connection)))
        #expect(AppActions.isWorthRetrying(PodMetricsFailure.malformed))
        #expect(!AppActions.isWorthRetrying(APIError.http(code: 401, resource: "pods")))
        #expect(!AppActions.isWorthRetrying(APIError.http(code: 403, resource: "pods")))
        #expect(!AppActions.isWorthRetrying(APIError.invalidRequest))
        #expect(!AppActions.isWorthRetrying(APIError.tls(.trustEvaluationFailed)))
        #expect(!AppActions.isWorthRetrying(PollStop.credentials.error))
    }

    /// RBAC can deny one namespace and allow another, so a 403 stops this poll without deciding
    /// anything about the cluster.
    @Test func aDeniedNamespaceStopsItsPollWithoutJudgingTheCluster() async throws {
        let metrics = ScriptedMetrics([.failure(APIError.http(code: 403, resource: "pods"))])
        let (store, actions, _) = try owner(metrics)
        actions.refreshList()
        try await appEventually { await metrics.calls.count == 1 }
        try await Task.sleep(for: .milliseconds(60))
        #expect(await metrics.calls.count == 1)
        #expect(store.clusters[0].metrics == .unknown)
        await actions.shutdownAndWait()
    }

    /// A restarting metrics-server is worth asking again; numbers that stop being refreshed are kept
    /// for a while, then cleared rather than shown as current.
    @Test func transientFailuresKeepPollingAndStaleNumbersAreEventuallyCleared() async throws {
        let clock = TestClock()
        let metrics = ScriptedMetrics([.success([web]), .failure(APIError.http(code: 503, resource: "pods"))])
        let (store, actions, _) = try owner(metrics, clock: clock)
        actions.refreshList()
        try await appEventually { store.podMetrics?["web"] != nil }
        let failing = await metrics.calls.count
        try await appEventually { await metrics.calls.count >= failing + 2 }
        #expect(store.podMetrics?["web"] == web)
        clock.advance(AppActions.metricsStaleAfter + 1)
        try await appEventually { store.podMetrics == [:] }
        // The cluster still serves metrics: the columns stay, showing blanks.
        #expect(store.clusters[0].metrics == .available)
        #expect(store.listTable.columns.contains { $0.kind == .cpu })
        await actions.shutdownAndWait()
    }

    /// The poll belongs to the watch's scope: a new namespace retires it, and the old poll's late
    /// answer describes pods that are no longer on screen.
    @Test func aNewScopeRetiresThePollAndDiscardsItsLateAnswer() async throws {
        let gate = AppTestGate()
        let metrics = ScriptedMetrics([.success([web])], gate: gate)
        let (store, actions, _) = try owner(metrics)
        let initial = store.selectedNamespace
        actions.refreshList()
        try await appEventually { await metrics.calls.count == 1 }
        try actions.selectNamespace("other")
        #expect(store.podMetrics == nil)
        // The Pods page is not open in this test, so the watch is restarted the way it opens one.
        actions.refreshList()
        try await appEventually { await metrics.calls.count == 2 }
        await gate.open()
        try await appEventually { store.podMetrics?["web"] != nil }
        #expect(await Array(metrics.calls.prefix(2)) == [initial, "other"])
        await actions.shutdownAndWait()
    }

    @Test func disconnectForgetsWhetherTheClusterServedMetrics() async throws {
        let metrics = ScriptedMetrics([.success([web])])
        let (store, actions, _) = try owner(metrics)
        store.clusters[0].state = .connected
        actions.refreshList()
        try await appEventually { store.clusters[0].metrics == .available }
        actions.disconnect(contextNamed: store.clusters[0].id)
        #expect(store.clusters[0].metrics == .unknown && store.podMetrics == nil)
        await actions.shutdownAndWait()
    }

    @Test func shutdownJoinsAPollWaitingOnTheServer() async throws {
        let gate = AppTestGate()
        let metrics = ScriptedMetrics([.success([web])], gate: gate)
        let (_, actions, _) = try owner(metrics)
        actions.refreshList()
        try await appEventually {
            let waiting = await gate.count
            return await metrics.calls.count == 1 && waiting == 1
        }
        await actions.shutdownAndWait()
        // Joined: the request waiting on the server was cancelled, and nothing asks again.
        let waiting = await gate.count
        #expect(actions.podMetricsTask == nil && waiting == 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await metrics.calls.count == 1)
    }
}
