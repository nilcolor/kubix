import Foundation
@testable import KubixCore
import Testing

/// Two kinds, still one watch. These cover what having a second list row can break: a watch left
/// running for the kind the user navigated away from, a stale update rendered under the new kind's
/// columns, and a metrics poll started for a kind that has no numbers to poll for.
@Suite @MainActor struct DeploymentSelectionTests {
    private func connected(
        _ lists: PodActionProbe, metrics: ScriptedMetrics? = nil
    ) async throws -> (AppStore, AppActions) {
        let probe = ClusterTestProbe()
        let store = AppStore(contexts: [try appContext()])
        let actions = AppActions(
            store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces(),
            lists: lists, probe: probe, metrics: metrics, metricsInterval: .milliseconds(10)
        )
        await probe.open()
        actions.connect(contextNamed: "first")
        try await appEventually { store.clusters[0].state == .connected }
        return (store, actions)
    }

    @Test func switchingKindRetiresThePreviousWatchAndStartsTheNewOne() async throws {
        let lists = PodActionProbe()
        let (store, actions) = try await connected(lists)
        defer { actions.shutdown() }

        actions.selectSidebar(.list("first", .pods))
        try await appEventually { await lists.callbacks.count == 1 }
        #expect(store.listKind == .pods)

        actions.selectSidebar(.list("first", .deployments))
        try await appEventually { await lists.callbacks.count == 2 }
        try await appEventually { await lists.ended == 1 }
        #expect(await lists.targets.map(\.kind) == [.pods, .deployments])
        #expect(store.listKind == .deployments && store.sidebarSelection == .list("first", .deployments))
        #expect(actions.retiringListTasks.isEmpty)

        // Back again is another switch, not a no-op: the deployments watch must not be left running.
        actions.selectSidebar(.list("first", .pods))
        try await appEventually { await lists.callbacks.count == 3 }
        try await appEventually { await lists.ended == 2 }
        #expect(store.listKind == .pods)
        await actions.shutdownAndWait()
    }

    /// The slot is emptied and re-labelled before the new watch publishes anything, so the pane
    /// cannot draw one kind's rows against the other's columns while the first page is in flight.
    @Test func anUpdateFromTheAbandonedKindCannotReachTheStore() async throws {
        let lists = PodActionProbe()
        let (store, actions) = try await connected(lists)
        defer { actions.shutdown() }
        actions.selectSidebar(.list("first", .pods))
        try await appEventually { await lists.callbacks.count == 1 }
        let table = try presentationTable(cells: [#"["zulu"]"#])
        let rows = try table.rows.map(ResourceRow.init)
        await lists.emit(.init(kind: .pods, rows: rows, columns: table.columnDefinitions, connection: .live))
        #expect(store.rows.count == 1 && store.connection == .live)

        actions.selectSidebar(.list("first", .deployments))
        try await appEventually { await lists.callbacks.count == 2 }
        #expect(store.rows.isEmpty && store.columns == nil)
        // The retained pods callback is both a stale generation and the wrong kind.
        await lists.emit(.init(kind: .pods, rows: rows, columns: table.columnDefinitions, connection: .live), call: 0)
        #expect(store.rows.isEmpty && store.connection == .connecting)
        await actions.shutdownAndWait()
    }

    @Test func deploymentsStartNoMetricsPollAndPodsStillDo() async throws {
        let lists = PodActionProbe()
        let metrics = ScriptedMetrics([.success([])])
        let (store, actions) = try await connected(lists, metrics: metrics)
        defer { actions.shutdown() }

        actions.selectSidebar(.list("first", .deployments))
        try await appEventually { await lists.callbacks.count == 1 }
        #expect(store.listKind == .deployments)
        #expect(await metrics.calls.isEmpty)

        actions.selectSidebar(.list("first", .pods))
        try await appEventually { await metrics.calls.isEmpty == false }
        await actions.shutdownAndWait()
    }

    /// Both rows are a list on a connected cluster, so both lose their pane the moment it stops
    /// being connected — and neither can be selected on a cluster that never was.
    @Test func disconnectDemotesADeploymentsSelectionToTheClusterRow() async throws {
        let lists = PodActionProbe()
        let (store, actions) = try await connected(lists)
        defer { actions.shutdown() }
        actions.selectSidebar(.list("first", .deployments))
        #expect(store.sidebarSelection == .list("first", .deployments))
        actions.disconnect(contextNamed: "first")
        #expect(store.sidebarSelection == .cluster("first"))
        #expect(store.rows.isEmpty && store.connection == .idle)

        actions.selectSidebar(.list("first", .deployments))
        #expect(store.sidebarSelection == .cluster("first"))
        await actions.shutdownAndWait()
    }

    /// A namespace commit lists whichever kind is selected, not pods.
    @Test func committingANamespaceRelistsTheSelectedKind() async throws {
        let lists = PodActionProbe()
        let (store, actions) = try await connected(lists)
        defer { actions.shutdown() }
        actions.selectSidebar(.list("first", .deployments))
        try await appEventually { await lists.callbacks.count == 1 }
        try actions.selectNamespace("other")
        try await appEventually { await lists.callbacks.count == 2 }
        #expect(await lists.targets.map(\.kind) == [.deployments, .deployments])
        #expect(await lists.targets.map(\.namespace) == ["first-namespace", "other"])
        #expect(store.listKind == .deployments)
        await actions.shutdownAndWait()
    }
}

/// What a deployments list refuses. The pane hides the pod-only actions, but hiding a button is not
/// a guarantee: the actions themselves read the list slot, so they are what must refuse.
@Suite @MainActor struct DeploymentActionTests {
    /// Both kinds have logs, by different routes. Only a pod has a container to exec into.
    @Test func theKindDecidesWhichActionsThePaneOffers() {
        #expect(ResourceKind.allCases.allSatisfy { $0.supportsLogs })
        #expect(ResourceKind.pods.supportsShell)
        #expect(!ResourceKind.deployments.supportsShell)
    }

    /// A deployment UID sent to the pods endpoint would read as a pod name, so neither action may
    /// reach the details request at all.
    @Test func neitherPodActionTouchesADeploymentRow() async throws {
        let details = RecordingPodDetails()
        let store = AppStore(contexts: [try appContext()])
        let actions = AppActions(
            store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces(),
            lists: PodActionProbe(), podDetails: details
        )
        defer { actions.shutdown() }
        let table = try presentationTable(cells: [#"["web"]"#])
        let rows = try table.rows.map(ResourceRow.init)
        actions.clearList(.deployments)
        actions.applyListUpdate(.init(kind: .deployments, rows: rows, columns: table.columnDefinitions, connection: .live))
        actions.selectRow(uid: "uid-0")
        #expect(store.listTable.selectedUID == "uid-0")

        // Both pod actions read the list slot, where a deployment UID would be sent to the pods
        // endpoint as if it named a pod. The deployment's own log action is a different request.
        actions.openPodShell(uid: "uid-0")
        actions.openPodLogs(uid: "uid-0")
        #expect(await details.requests.isEmpty)
        #expect(store.execSessions.isEmpty && store.logSessions.isEmpty)
        // And no diagnostic either: a hidden action that was never offered has nothing to explain.
        #expect(store.podShellDiagnostic == nil && store.podLogDiagnostic == nil)
        await actions.shutdownAndWait()
    }
}

private actor RecordingPodDetails: PodDetailsProviding {
    private(set) var requests: [String] = []
    func details(context: ResolvedContext, namespace: String, name: String, uid: String) async throws -> PodDetails {
        requests.append(name)
        throw PodDetailsError.malformed
    }
}
