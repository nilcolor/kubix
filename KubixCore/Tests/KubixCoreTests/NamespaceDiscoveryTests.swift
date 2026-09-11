import Foundation
import KubixCore
import Testing

@Suite struct NamespaceDiscoveryTests {
    @Test func aListedResultIsSortedDeduplicatedAndFreeOfUnselectableNames() throws {
        let context = try appContext()
        let selection = NamespaceSelection()
        let discovery = NamespaceDiscovery.listed(["zulu", "alpha", "zulu", "UPPER", "bad/name", "", "team"])
        #expect(selection.options(for: context, discovery: discovery) == ["alpha", "team", "zulu"])
    }

    @Test func anEmptyListedResultIsNotTheSameAsNotKnowing() throws {
        let context = try appContext()
        var selection = NamespaceSelection()
        try selection.remember("remembered", for: context)
        // A cluster that genuinely has no namespaces must not fall back to stale local history.
        #expect(selection.options(for: context, discovery: .listed([])).isEmpty)
        #expect(selection.options(for: context, discovery: .unknown) == ["first-namespace", "remembered"])
    }

    @Test(arguments: [NamespaceDiscovery.unknown, .unavailable])
    func withoutAListTheOptionsAreExactlyTodaysSuggestions(_ discovery: NamespaceDiscovery) throws {
        let context = try appContext()
        var selection = NamespaceSelection()
        try selection.remember("known", for: context)
        try selection.remember("other", for: context)
        #expect(selection.options(for: context, discovery: discovery) == selection.suggestions(for: context))
        #expect(selection.options(for: context, discovery: discovery) == ["first-namespace", "known", "other"])
    }

    @Test func historySurvivesAListSoLosingThePermissionDoesNotLoseIt() throws {
        let context = try appContext()
        var selection = NamespaceSelection()
        try selection.remember("typed", for: context)
        #expect(selection.options(for: context, discovery: .listed(["alpha"])) == ["alpha"])
        #expect(selection.options(for: context, discovery: .unavailable) == ["first-namespace", "typed"])
    }

    @Test func withoutAContextTheFallbackStaysTheDefaultNamespace() {
        #expect(NamespaceSelection().options(for: nil, discovery: .unknown) == ["default"])
        #expect(NamespaceSelection().options(for: nil, discovery: .listed(["alpha"])) == ["alpha"])
    }

    @Test func reconcileCarriesDiscoveryOnlyForAnUnchangedSnapshot() throws {
        let first = try appContext()
        let second = try appContext("second")
        let existing = [
            ClusterStatus(context: first, state: .connected, namespaces: .listed(["alpha"])),
            ClusterStatus(context: second, state: .connected, namespaces: .unavailable),
        ]

        let reconciled = ClusterStatus.reconcile(existing: existing, contexts: [first, try redefinedContext("second")])
        #expect(reconciled[0].namespaces == .listed(["alpha"]))
        #expect(reconciled[1].namespaces == .unknown)
        #expect(reconciled[1].state == .disconnected)

        let readded = ClusterStatus.reconcile(existing: [], contexts: [first])
        #expect(readded[0].namespaces == .unknown)
    }
}

@Suite @MainActor struct NamespaceOptionTests {
    @Test func theOptionsFollowTheFocusedClusterAndNotABackgroundOne() async throws {
        let probe = ClusterTestProbe()
        await probe.open()
        let lister = NamespaceTestLister(names: ["from-first"])
        let store = AppStore(contexts: [try appContext(), try appContext("second")])
        let actions = AppActions(
            store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces(),
            pods: PodActionProbe(), probe: probe, namespaces: lister
        )
        defer { actions.shutdown() }
        #expect(store.namespaces == ["first-namespace"])

        actions.connect(contextNamed: "first")
        try await appEventually { store.namespaces == ["from-first"] }

        // "second" is focused but was never listed, so its own history shows instead.
        actions.selectSidebar(.cluster("second"))
        #expect(store.namespaces == ["second-namespace"])

        // A background cluster finishing a list must not replace what is on screen.
        await lister.succeed(with: ["from-first-again"])
        actions.connect(contextNamed: "first")
        try await appEventually { store.clusters[0].namespaces == .listed(["from-first-again"]) }
        #expect(store.namespaces == ["second-namespace"])

        actions.selectSidebar(.cluster("first"))
        #expect(store.namespaces == ["from-first-again"])
        await actions.shutdownAndWait()
    }

    @Test func typedHistoryIsStillRecordedWhileAListExists() async throws {
        let probe = ClusterTestProbe()
        await probe.open()
        let store = AppStore(contexts: [try appContext()])
        let actions = AppActions(
            store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces(),
            pods: PodActionProbe(), probe: probe, namespaces: NamespaceTestLister(names: ["listed-one"])
        )
        defer { actions.shutdown() }
        actions.connect(contextNamed: "first")
        try await appEventually { store.namespaces == ["listed-one"] }

        try actions.selectNamespace("typed-one")
        #expect(store.namespaces == ["listed-one"])

        // Losing the permission later must not lose what the user typed while it worked.
        actions.disconnect(contextNamed: "first")
        #expect(store.namespaces == ["first-namespace", "typed-one"])
        await actions.shutdownAndWait()
    }
}
