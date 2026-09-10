import Foundation
import KubixCore
import Testing

struct NamespaceSelectionTests {
    @Test @MainActor func configurationLoadingNeverImplicitlyStartsDiscoveryAndReloadCancelsTheCurrentWatch() async throws {
        let probe = PodActionProbe()
        let store = AppStore()
        let actions = AppActions(
            store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces(),
            configurations: PodConfiguration(), pods: probe
        )
        defer { actions.shutdown() }
        await actions.loadConfiguration()
        #expect(store.selectedNamespace == "first-namespace" && store.connection == .idle)
        #expect(await probe.callbacks.isEmpty)
        actions.refreshPods()
        try await appEventually { await probe.callbacks.count == 1 }
        await actions.loadConfiguration()
        try await appEventually { await probe.ended == 1 }
        #expect(store.connection == .idle)
        await probe.emit(PodWatchUpdate(rows: [], columns: nil, connection: .live))
        #expect(store.connection == .idle)
        await actions.shutdownAndWait()
    }

    @Test(arguments: ["default", "a", "0", "team-9", String(repeating: "a", count: 63)])
    func acceptsDNSLabels(_ name: String) {
        #expect(NamespaceSelection.isValid(name))
    }

    private struct PodConfiguration: AppConfigurationLoading {
        func load() -> AppConfiguration {
            var snapshot = AppConfiguration(configuration: nil, settings: nil)
            snapshot.contexts = [try! appContext()]
            return snapshot
        }
    }

    @Test(arguments: ["", ".", "..", "a/b", "a.b", "-team", "team-", "TEAM", "team_name", "team name", "équipe", "x\n", String(repeating: "a", count: 64)])
    func rejectsInvalidNamesLocally(_ name: String) {
        #expect(!NamespaceSelection.isValid(name))
    }

    @Test @MainActor func defaultsAndSuggestionsArePerContextAndDraftsDoNotCommit() throws {
        let first = try appContext()
        let second = try appContext("second")
        let store = AppStore(contexts: [first, second])
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces())
        defer { actions.shutdown() }
        #expect(AppStore().selectedNamespace == "default")
        #expect(store.selectedNamespace == "first-namespace" && store.namespaceDraft == "first-namespace")
        actions.setNamespaceInput("bad/input")
        #expect(store.selectedNamespace == "first-namespace" && store.namespaceDraft == "bad/input")
        #expect(!actions.commitNamespaceInput() && store.namespaceDiagnostic != nil)
        actions.setNamespaceInput("known")
        #expect(actions.commitNamespaceInput())
        try actions.selectNamespace("known")
        #expect(store.namespaces == ["first-namespace", "known"])
        try actions.selectContext(named: second.name)
        #expect(store.selectedNamespace == "second-namespace" && store.namespaces == ["second-namespace"])
        try actions.selectNamespace("other-known")
        try actions.selectContext(named: first.name)
        #expect(store.namespaces == ["first-namespace", "known"])
        #expect(store.namespaceDraft == "first-namespace")
        #expect(store.namespaceDiagnostic == nil)
    }
}

actor PodActionProbe: PodWatching {
    let gate = AppTestGate()
    private(set) var callbacks: [@MainActor @Sendable (PodWatchUpdate) -> Void] = []
    private(set) var ended = 0
    func run(
        context: ResolvedContext, namespace: String, update: @escaping @MainActor @Sendable (PodWatchUpdate) -> Void
    ) async {
        callbacks.append(update)
        do { try await gate.wait() } catch is CancellationError {
            // Deliberately retain callbacks to exercise the mutation seam's generation guard.
        } catch { Issue.record("Unexpected gate error.") }
        ended += 1
    }
    func emit(_ value: PodWatchUpdate, call: Int = 0) async { await callbacks[call](value) }
}
