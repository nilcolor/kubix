import Foundation
@testable import KubixCore
import Testing

@Suite @MainActor struct ClusterConnectionTests {
    private func makeActions(
        probe: ClusterTestProbe?, pods: PodActionProbe, contexts: [ResolvedContext]
    ) -> (AppStore, AppActions) {
        let store = AppStore(contexts: contexts)
        let actions = AppActions(
            store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces(),
            pods: pods, probe: probe
        )
        return (store, actions)
    }

    @Test func connectingReachesConnectedWithoutListingAnyPods() async throws {
        let probe = ClusterTestProbe()
        let pods = PodActionProbe()
        let (store, actions) = makeActions(probe: probe, pods: pods, contexts: [try appContext(), try appContext("second")])
        defer { actions.shutdown() }

        actions.connect(contextNamed: "first")
        #expect(store.clusters[0].state == .connecting)
        #expect(store.clusters[1].state == .disconnected)
        try await appEventually { await probe.contexts.count == 1 }
        #expect(await probe.contexts.first?.name == "first")
        #expect(await pods.callbacks.isEmpty)
        #expect(store.connection == .idle)

        await probe.open()
        try await appEventually { store.clusters[0].state == .connected }
        // The version the pane shows comes from the same probe, not a second request.
        #expect(store.clusters[0].serverVersion == "v1.30.0-test")
        #expect(store.clusters[1].serverVersion == nil)
        #expect(await pods.callbacks.isEmpty)
        #expect(store.connection == .idle)
        await actions.shutdownAndWait()
    }

    @Test(arguments: [
        ClusterTestProbe.Failure.forbidden, .unauthorized, .credentials, .certificate, .proxy,
    ])
    func everyFailureShapeLandsAReadableReasonAndNoWatch(_ failure: ClusterTestProbe.Failure) async throws {
        let probe = ClusterTestProbe(failure: failure)
        let pods = PodActionProbe()
        let (store, actions) = makeActions(probe: probe, pods: pods, contexts: [try appContext()])
        defer { actions.shutdown() }

        actions.connect(contextNamed: "first")
        await probe.open()
        try await appEventually {
            if case .failed = store.clusters[0].state { return true }
            return false
        }
        guard case .failed(let reason) = store.clusters[0].state else { throw AppTestError.injected }
        #expect(!reason.isEmpty)
        #expect(reason == failure.expectedReason)
        #expect(await pods.callbacks.isEmpty)
        #expect(store.connection == .idle)
        await actions.shutdownAndWait()
    }

    @Test(arguments: [true, false])
    func asupersededConnectNeverWritesItsOutcome(_ staleSucceeds: Bool) async throws {
        let probe = ClusterTestProbe(failure: staleSucceeds ? nil : .forbidden)
        let (store, actions) = makeActions(probe: probe, pods: PodActionProbe(), contexts: [try appContext()])
        defer { actions.shutdown() }

        actions.connect(contextNamed: "first")
        try await appEventually { await probe.contexts.count == 1 }
        // The second attempt supersedes the first while the first is still in flight.
        actions.connect(contextNamed: "first")
        try await appEventually { await probe.contexts.count == 2 }
        #expect(store.clusters[0].state == .connecting)

        await probe.open()
        try await appEventually { store.clusters[0].state != .connecting }
        if staleSucceeds {
            #expect(store.clusters[0].state == .connected)
        } else {
            #expect(store.clusters[0].state == .failed(reason: ClusterTestProbe.Failure.forbidden.expectedReason))
        }
        await actions.shutdownAndWait()
    }

    @Test func disconnectCancelsOnlyTheActiveClustersWatchAndClosesNoSessions() async throws {
        let probe = ClusterTestProbe()
        let pods = PodActionProbe()
        let (store, actions) = makeActions(probe: probe, pods: pods, contexts: [try appContext(), try appContext("second")])
        defer { actions.shutdown() }
        await probe.open()
        actions.connect(contextNamed: "first")
        actions.connect(contextNamed: "second")
        try await appEventually { store.clusters.allSatisfy { $0.state == .connected } }

        let session = actions.openShell(target: try appTarget())
        actions.refreshPods()
        try await appEventually { await pods.callbacks.count == 1 }
        #expect(store.connection == .connecting)

        // "second" does not own the active watch, which belongs to the selected context.
        actions.disconnect(contextNamed: "second")
        #expect(store.clusters[1].state == .disconnected)
        #expect(store.connection == .connecting)
        #expect(store.execSessions.contains { $0.id == session && !$0.isClosed })

        actions.disconnect(contextNamed: "first")
        #expect(store.clusters[0].state == .disconnected)
        #expect(store.connection == .idle)
        try await appEventually { await pods.ended == 1 }
        #expect(store.execSessions.contains { $0.id == session && !$0.isClosed })
        await actions.shutdownAndWait()
    }

    @Test func anInFlightProbeIsCancelledAndJoinedByShutdown() async throws {
        let probe = ClusterTestProbe()
        let (store, actions) = makeActions(probe: probe, pods: PodActionProbe(), contexts: [try appContext()])
        actions.connect(contextNamed: "first")
        try await appEventually { await probe.contexts.count == 1 }

        await actions.shutdownAndWait()
        #expect(await probe.cancellations == 1)
        #expect(store.clusters[0].state == .connecting)
    }

    @Test func onlyAPodsSelectionOnAConnectedClusterStartsDiscovery() async throws {
        let probe = ClusterTestProbe()
        let pods = PodActionProbe()
        let (store, actions) = makeActions(probe: probe, pods: pods, contexts: [try appContext(), try appContext("second")])
        defer { actions.shutdown() }

        // A disconnected cluster cannot be browsed, and its row is focus alone.
        actions.selectSidebar(.pods("first"))
        #expect(store.sidebarSelection == .cluster("first"))
        #expect(await pods.callbacks.isEmpty)
        actions.selectSidebar(.cluster("second"))
        #expect(store.sidebarSelection == .cluster("second"))
        #expect(store.selectedContext?.name == "second")
        #expect(await pods.callbacks.isEmpty)
        #expect(store.connection == .idle)

        // A context change on its own is still not a request to list.
        try actions.selectContext(named: "first")
        #expect(await pods.callbacks.isEmpty)

        await probe.open()
        actions.connect(contextNamed: "first")
        try await appEventually { store.clusters[0].state == .connected }
        actions.selectSidebar(.pods("first"))
        #expect(store.sidebarSelection == .pods("first"))
        try await appEventually { await pods.callbacks.count == 1 }
        #expect(await pods.targets.map(\.context.name) == ["first"])

        // Reselecting the same live node must not restart the watch.
        actions.selectSidebar(.pods("first"))
        #expect(await pods.callbacks.count == 1)
        await actions.shutdownAndWait()
    }

    @Test func movingPodsBetweenClustersLeavesExactlyOneWatchAndJoinsThePrevious() async throws {
        let probe = ClusterTestProbe()
        let pods = PodActionProbe()
        let (store, actions) = makeActions(probe: probe, pods: pods, contexts: [try appContext(), try appContext("second")])
        defer { actions.shutdown() }
        await probe.open()
        actions.connect(contextNamed: "first")
        actions.connect(contextNamed: "second")
        try await appEventually { store.clusters.allSatisfy { $0.state == .connected } }

        actions.selectSidebar(.pods("first"))
        try await appEventually { await pods.callbacks.count == 1 }
        actions.selectSidebar(.pods("second"))
        try await appEventually { await pods.callbacks.count == 2 }
        try await appEventually { await pods.ended == 1 }
        #expect(actions.retiringPodTasks.isEmpty)
        #expect(await pods.targets.map(\.context.name) == ["first", "second"])
        #expect(store.sidebarSelection == .pods("second"))

        // A late update from the abandoned cluster cannot reach the store.
        let table = try presentationTable(cells: [#"["zulu"]"#])
        await pods.emit(.init(rows: try table.rows.map(PodRow.init), columns: table.columnDefinitions, connection: .live), call: 0)
        #expect(store.rows.isEmpty && store.connection == .connecting)
        await actions.shutdownAndWait()
    }

    @Test func disconnectDemotesAPodsSelectionAndAFailedConnectNeverLeavesOneBehind() async throws {
        let probe = ClusterTestProbe()
        let (store, actions) = makeActions(probe: probe, pods: PodActionProbe(), contexts: [try appContext()])
        defer { actions.shutdown() }
        await probe.open()
        actions.connect(contextNamed: "first")
        try await appEventually { store.clusters[0].state == .connected }
        actions.selectSidebar(.pods("first"))
        #expect(store.sidebarSelection == .pods("first"))

        actions.disconnect(contextNamed: "first")
        #expect(store.sidebarSelection == .cluster("first"))

        let failing = ClusterTestProbe(failure: .forbidden)
        await failing.open()
        let (otherStore, otherActions) = makeActions(probe: failing, pods: PodActionProbe(), contexts: [try appContext()])
        defer { otherActions.shutdown() }
        otherActions.selectSidebar(.cluster("first"))
        otherActions.connect(contextNamed: "first")
        try await appEventually {
            if case .failed = otherStore.clusters[0].state { return true }
            return false
        }
        #expect(otherStore.sidebarSelection == .cluster("first"))
        await actions.shutdownAndWait()
        await otherActions.shutdownAndWait()
    }

    @Test func connectWhileConnectingAndDisconnectMidConnectAreBothSafe() async throws {
        let probe = ClusterTestProbe()
        let (store, actions) = makeActions(probe: probe, pods: PodActionProbe(), contexts: [try appContext()])
        defer { actions.shutdown() }

        actions.connect(contextNamed: "first")
        actions.connect(contextNamed: "first")
        try await appEventually { await probe.contexts.count == 2 }
        actions.disconnect(contextNamed: "first")
        #expect(store.clusters[0].state == .disconnected)
        await probe.open()
        // The abandoned probe must not resurrect a disconnected cluster.
        try await appEventually { await probe.cancellations >= 1 }
        #expect(store.clusters[0].state == .disconnected)
        await actions.shutdownAndWait()
    }

    @Test func connectIsANoOpWithoutAProbeOrForAnUnknownCluster() async throws {
        let pods = PodActionProbe()
        let (store, actions) = makeActions(probe: nil, pods: pods, contexts: [try appContext()])
        defer { actions.shutdown() }
        actions.connect(contextNamed: "first")
        actions.connect(contextNamed: "missing")
        actions.disconnect(contextNamed: "missing")
        #expect(store.clusters[0].state == .disconnected)
        #expect(await pods.callbacks.isEmpty)
        await actions.shutdownAndWait()
    }
}

@Suite @MainActor struct ClusterReloadTests {
    private func makeActions(
        probe: ClusterTestProbe, loader: ReloadableClusterLoader, pods: PodActionProbe
    ) -> (AppStore, AppActions) {
        let store = AppStore()
        let actions = AppActions(
            store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces(),
            configurations: loader, pods: pods, probe: probe
        )
        return (store, actions)
    }

    @Test func aReloadThatRemovesOrRedefinesAConnectedClusterStopsItsWatch() async throws {
        let probe = ClusterTestProbe()
        let pods = PodActionProbe()
        let loader = ReloadableClusterLoader(contexts: [try appContext(), try appContext("second")])
        let (store, actions) = makeActions(probe: probe, loader: loader, pods: pods)
        defer { actions.shutdown() }
        await probe.open()
        await actions.loadConfiguration()
        actions.connect(contextNamed: "first")
        try await appEventually { store.clusters[0].state == .connected }
        actions.selectSidebar(.pods("first"))
        try await appEventually { await pods.callbacks.count == 1 }

        await loader.replace(contexts: [try appContext("second")])
        await actions.loadConfiguration()

        #expect(store.clusters.map(\.id) == ["second"])
        #expect(store.sidebarSelection == .cluster("second"))
        #expect(store.connection == .idle)
        try await appEventually { await pods.ended == 1 }
        await actions.shutdownAndWait()
    }

    @Test func aConnectedClusterWhoseSnapshotChangedReturnsToDisconnected() async throws {
        let probe = ClusterTestProbe()
        let loader = ReloadableClusterLoader(contexts: [try appContext()])
        let (store, actions) = makeActions(probe: probe, loader: loader, pods: PodActionProbe())
        defer { actions.shutdown() }
        await probe.open()
        await actions.loadConfiguration()
        actions.connect(contextNamed: "first")
        try await appEventually { store.clusters[0].state == .connected }
        actions.selectSidebar(.pods("first"))

        await loader.replace(contexts: [try redefinedContext("first")])
        await actions.loadConfiguration()

        #expect(store.clusters[0].state == .disconnected)
        #expect(store.sidebarSelection == .cluster("first"))
        #expect(store.connection == .idle)
        await actions.shutdownAndWait()
    }

    @Test func aProbeCannotReportOnASnapshotItNeverRanAgainst() async throws {
        let probe = ClusterTestProbe()
        let loader = ReloadableClusterLoader(contexts: [try appContext()])
        let (store, actions) = makeActions(probe: probe, loader: loader, pods: PodActionProbe())
        defer { actions.shutdown() }
        await actions.loadConfiguration()
        actions.connect(contextNamed: "first")
        try await appEventually { await probe.contexts.count == 1 }

        // "first" is redefined while its probe is in flight: same name, different server.
        await loader.replace(contexts: [try redefinedContext("first")])
        await actions.loadConfiguration()
        #expect(store.clusters[0].state == .disconnected)

        // Letting the probe finish and joining it is what proves the result was discarded rather
        // than merely delayed: without the snapshot check it lands as connected or failed here.
        await probe.open()
        await actions.shutdownAndWait()
        #expect(store.clusters[0].state == .disconnected)
        #expect(await probe.contexts.count == 1)
    }
}

actor ClusterTestProbe: ClusterProbing {
    enum Failure: Sendable {
        case forbidden, unauthorized, credentials, certificate, proxy

        var error: any Error {
            switch self {
            case .forbidden: APIError.http(code: 403, resource: "version")
            case .unauthorized: APIError.http(code: 401, resource: "version")
            case .credentials: AuthError.missingCredentials
            case .certificate: AuthenticationError.unsupportedCertificate
            case .proxy: KubeconfigError.unsupportedProxy
            }
        }

        var expectedReason: String {
            switch self {
            case .forbidden, .unauthorized: (error as? APIError)?.description ?? ""
            case .credentials: AuthError.missingCredentials.description
            case .certificate: AuthenticationError.unsupportedCertificate.errorDescription ?? ""
            case .proxy: KubeconfigError.unsupportedProxy.description
            }
        }
    }

    private let gate = AppTestGate()
    private let failure: Failure?
    private(set) var contexts: [ResolvedContext] = []
    private(set) var cancellations = 0

    init(failure: Failure? = nil) { self.failure = failure }

    func open() async { await gate.open() }

    func probe(context: ResolvedContext) async throws -> String? {
        contexts.append(context)
        do { try await gate.wait() } catch {
            cancellations += 1
            throw error
        }
        if let failure { throw failure.error }
        return "v1.30.0-test"
    }
}

func redefinedContext(_ name: String) throws -> ResolvedContext {
    try Kubeconfig(
        currentContext: name,
        clusters: [.init(name: name, cluster: .init(server: "https://\(name).redefined.invalid"))],
        contexts: [.init(name: name, context: .init(cluster: name, namespace: "\(name)-namespace"))]
    ).resolve()
}

actor ReloadableClusterLoader: AppConfigurationLoading {
    private var contexts: [ResolvedContext]

    init(contexts: [ResolvedContext]) { self.contexts = contexts }
    func replace(contexts: [ResolvedContext]) { self.contexts = contexts }

    func load() -> AppConfiguration {
        var snapshot = AppConfiguration(configuration: nil, settings: nil)
        snapshot.contexts = contexts
        return snapshot
    }
}
