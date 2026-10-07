import Foundation
import KubixCore
import Testing

private func changedContext(_ name: String) throws -> ResolvedContext {
    try Kubeconfig(
        currentContext: name,
        clusters: [.init(name: name, cluster: .init(server: "https://\(name).changed.invalid"))],
        contexts: [.init(name: name, context: .init(cluster: name, namespace: "\(name)-namespace"))]
    ).resolve()
}

@Suite struct ClusterStatusTests {
    @Test func statesAndSelectionsCompareByValue() throws {
        let context = try appContext()
        #expect(ClusterStatus(context: context, state: .failed(reason: "a")) != ClusterStatus(context: context, state: .failed(reason: "b")))
        #expect(ClusterStatus(context: context) == ClusterStatus(context: context, state: .disconnected))
        #expect(ClusterStatus(context: context).id == "first")
        #expect(SidebarSelection.cluster("a") != SidebarSelection.list("a", .pods))
        #expect(SidebarSelection.list("a", .pods).clusterName == "a")
        #expect(Set([SidebarSelection.cluster("a"), .cluster("a"), .list("a", .pods)]).count == 2)
    }

    @Test func reconcileKeepsUnchangedSnapshotsAndResetsChangedOnes() throws {
        let first = try appContext()
        let second = try appContext("second")
        let existing = [
            ClusterStatus(context: first, state: .connected),
            ClusterStatus(context: second, state: .failed(reason: "boom")),
        ]

        let reordered = ClusterStatus.reconcile(existing: existing, contexts: [try changedContext("second"), first])
        #expect(reordered.map(\.id) == ["second", "first"])
        #expect(reordered[0].state == .disconnected)
        #expect(reordered[1].state == .connected)

        #expect(ClusterStatus.reconcile(existing: existing, contexts: [first]).map(\.id) == ["first"])
        #expect(ClusterStatus.reconcile(existing: [], contexts: [first]) == [ClusterStatus(context: first, state: .disconnected)])
        #expect(ClusterStatus.reconcile(existing: existing, contexts: []).isEmpty)
    }

    @Test func reconcileSelectionDemotesPodsAndRecoversFromRemovedClusters() throws {
        let clusters = [
            ClusterStatus(context: try appContext(), state: .connected),
            ClusterStatus(context: try appContext("second"), state: .connecting),
        ]
        #expect(SidebarSelection.reconcile(.list("first", .pods), clusters: clusters, preferred: "second") == .list("first", .pods))
        #expect(SidebarSelection.reconcile(.list("second", .pods), clusters: clusters, preferred: nil) == .cluster("second"))
        #expect(SidebarSelection.reconcile(.cluster("gone"), clusters: clusters, preferred: "second") == .cluster("second"))
        #expect(SidebarSelection.reconcile(.cluster("gone"), clusters: clusters, preferred: nil) == .cluster("first"))
        #expect(SidebarSelection.reconcile(nil, clusters: clusters, preferred: "second") == .cluster("second"))
        #expect(SidebarSelection.reconcile(.cluster("first"), clusters: [], preferred: "first") == nil)
    }
}

@Suite @MainActor struct ClusterLoadTests {
    @Test func loadingListsEveryClusterDisconnectedAndSelectsThePreferredRowWithoutWatching() async throws {
        let probe = PodActionProbe()
        let store = AppStore()
        let actions = AppActions(
            store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces(),
            configurations: ClusterTestLoader(contexts: [try appContext(), try appContext("second")], preferred: "second"),
            lists: probe
        )
        defer { actions.shutdown() }
        await actions.loadConfiguration()

        #expect(store.clusters.map(\.id) == ["first", "second"])
        #expect(store.clusters.allSatisfy { $0.state == .disconnected })
        #expect(store.sidebarSelection == .cluster("second"))
        #expect(store.selectedContext?.name == "second")
        #expect(store.connection == .idle)
        #expect(await probe.callbacks.isEmpty)
        await actions.shutdownAndWait()
    }

    @Test func reloadingReconcilesClustersAndRecoversASelectionWhoseClusterDisappeared() async throws {
        let probe = PodActionProbe()
        let store = AppStore()
        let loader = ClusterTestLoader(contexts: [try appContext(), try appContext("second")], preferred: "first")
        let actions = AppActions(
            store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces(),
            configurations: loader, lists: probe
        )
        defer { actions.shutdown() }
        await actions.loadConfiguration()
        #expect(store.sidebarSelection == .cluster("first"))

        await loader.replace(contexts: [try changedContext("second")], preferred: nil)
        await actions.loadConfiguration()

        #expect(store.clusters.map(\.id) == ["second"])
        #expect(store.clusters[0].state == .disconnected)
        #expect(store.sidebarSelection == .cluster("second"))
        #expect(store.selectedContext?.name == "second")
        #expect(store.connection == .idle)
        #expect(await probe.callbacks.isEmpty)
        await actions.shutdownAndWait()
    }
}

private actor ClusterTestLoader: AppConfigurationLoading {
    private var contexts: [ResolvedContext]
    private var preferred: String?

    init(contexts: [ResolvedContext], preferred: String?) {
        self.contexts = contexts
        self.preferred = preferred
    }

    func replace(contexts: [ResolvedContext], preferred: String?) {
        self.contexts = contexts
        self.preferred = preferred
    }

    func load() -> AppConfiguration {
        var snapshot = AppConfiguration(configuration: nil, settings: nil)
        snapshot.contexts = contexts
        snapshot.preferredContext = preferred
        return snapshot
    }
}

@Suite @MainActor struct PaneSizingTests {
    private func actions(_ store: AppStore) -> AppActions {
        AppActions(store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces())
    }

    @Test func theDeckOpensAtHalfAndClampsToItsBounds() throws {
        let store = AppStore()
        let actions = actions(store)
        defer { actions.shutdown() }
        // A shell is the reason the deck exists; the old automatic split opened it barely readable.
        #expect(store.deckFraction == 0.5)

        actions.setDeckFraction(0.3)
        #expect(store.deckFraction == 0.3)
        actions.setDeckFraction(0)
        #expect(store.deckFraction == AppStore.deckFractionMinimum)
        actions.setDeckFraction(1)
        #expect(store.deckFraction == AppStore.deckFractionMaximum)
        actions.setDeckFraction(.nan)
        #expect(store.deckFraction == AppStore.deckFractionMaximum)
    }

    @Test func aStoppedOwnerIgnoresAResize() throws {
        let store = AppStore()
        let actions = actions(store)
        actions.shutdown()
        actions.setDeckFraction(0.2)
        #expect(store.deckFraction == AppStore.deckFractionDefault)
    }
}
