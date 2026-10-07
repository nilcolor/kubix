import Foundation
@testable import KubixCore
import Testing

@Suite @MainActor struct NamespaceRefreshTests {
    private func connected(
        _ lister: NamespaceTestLister, clock: TestMonotonicClock = TestMonotonicClock(),
        pods: PodActionProbe = PodActionProbe()
    ) async throws -> (AppStore, AppActions, ClusterTestProbe) {
        let probe = ClusterTestProbe()
        await probe.open()
        let store = AppStore(contexts: [try appContext(), try appContext("second")])
        let actions = AppActions(
            store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces(),
            lists: pods, probe: probe, namespaces: lister, monotonicNow: clock.read
        )
        actions.connect(contextNamed: "first")
        try await appEventually { store.clusters[0].state == .connected }
        return (store, actions, probe)
    }

    @Test func aSuccessfulConnectListsNamespacesExactlyOnce() async throws {
        let lister = NamespaceTestLister(names: ["zulu", "alpha"])
        let (store, actions, _) = try await connected(lister)
        defer { actions.shutdown() }

        try await appEventually { store.clusters[0].namespaces == .listed(["zulu", "alpha"]) }
        #expect(await lister.contexts.map(\.name) == ["first"])
        #expect(store.clusters[1].namespaces == .unknown)
        await actions.shutdownAndWait()
    }

    @Test func aFailedListingIsSilentAndFinal() async throws {
        let lister = NamespaceTestLister(failure: APIError.http(code: 403, resource: "namespaces"))
        let (store, actions, _) = try await connected(lister)
        defer { actions.shutdown() }

        try await appEventually { store.clusters[0].namespaces == .unavailable }
        // A denied list is a normal configuration, not a problem to report.
        #expect(store.clusters[0].state == .connected)
        #expect(store.authenticationDiagnostic == nil)
        #expect(store.namespaceDiagnostic == nil)
        #expect(store.visibleAuthenticationSessions.isEmpty)

        // No path retries it on its own.
        actions.refreshNamespaces(contextNamed: "first")
        actions.selectSidebar(.list("first", .pods))
        #expect(await lister.contexts.count == 1)
        await actions.shutdownAndWait()
    }

    @Test func nothingIsListedBeforeOrWithoutASuccessfulConnect() async throws {
        let lister = NamespaceTestLister(names: ["alpha"])
        let probe = ClusterTestProbe(failure: .forbidden)
        await probe.open()
        let store = AppStore(contexts: [try appContext()])
        let actions = AppActions(
            store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces(),
            lists: PodActionProbe(), probe: probe, namespaces: lister
        )
        defer { actions.shutdown() }

        actions.refreshNamespaces(contextNamed: "first")
        #expect(await lister.contexts.isEmpty)
        actions.connect(contextNamed: "first")
        try await appEventually {
            if case .failed = store.clusters[0].state { return true }
            return false
        }
        #expect(await lister.contexts.isEmpty)
        #expect(store.clusters[0].namespaces == .unknown)
        await actions.shutdownAndWait()
    }

    @Test func refreshIsThrottledToOnceEveryThirtySeconds() async throws {
        let lister = NamespaceTestLister(names: ["alpha"])
        let clock = TestMonotonicClock()
        let (store, actions, _) = try await connected(lister, clock: clock)
        defer { actions.shutdown() }
        try await appEventually { await lister.contexts.count == 1 }

        clock.advance(29)
        actions.refreshNamespaces(contextNamed: "first")
        #expect(await lister.contexts.count == 1)

        clock.advance(1)
        actions.refreshNamespaces(contextNamed: "first")
        try await appEventually { await lister.contexts.count == 2 }
        #expect(store.clusters[0].namespaces == .listed(["alpha"]))
        await actions.shutdownAndWait()
    }

    @Test func anExplicitConnectResetsAndRetriesADeniedListing() async throws {
        let lister = NamespaceTestLister(failure: APIError.http(code: 403, resource: "namespaces"))
        let (store, actions, _) = try await connected(lister)
        defer { actions.shutdown() }
        try await appEventually { store.clusters[0].namespaces == .unavailable }

        // Pressing Connect is asking for the whole handshake again, permissions included.
        await lister.succeed(with: ["alpha"])
        actions.connect(contextNamed: "first")
        try await appEventually { store.clusters[0].namespaces == .listed(["alpha"]) }
        #expect(await lister.contexts.count == 2)
        await actions.shutdownAndWait()
    }

    @Test func aCredentialFailureWhileListingLeavesTheClusterConnected() async throws {
        let lister = NamespaceTestLister(failure: AuthError.missingCredentials)
        let (store, actions, _) = try await connected(lister)
        defer { actions.shutdown() }

        try await appEventually { store.clusters[0].namespaces == .unavailable }
        // Listing is not a connect attempt: its failure must not unseat the connection.
        #expect(store.clusters[0].state == .connected)
        #expect(store.authenticationDiagnostic == nil)
        await actions.shutdownAndWait()
    }

    @Test func aListForARedefinedOrDisconnectedClusterIsDiscarded() async throws {
        let lister = NamespaceTestLister(names: ["alpha"], gated: true)
        let (store, actions, _) = try await connected(lister)
        defer { actions.shutdown() }
        try await appEventually { await lister.contexts.count == 1 }

        actions.disconnect(contextNamed: "first")
        #expect(store.clusters[0].namespaces == .unknown)
        await lister.open()
        await actions.shutdownAndWait()
        #expect(store.clusters[0].namespaces == .unknown)
    }

    @Test func aRefreshWhileAFetchIsInFlightDoesNotStartASecond() async throws {
        let lister = NamespaceTestLister(names: ["alpha"], gated: true)
        let (store, actions, _) = try await connected(lister)
        defer { actions.shutdown() }
        try await appEventually { await lister.contexts.count == 1 }

        for _ in 0..<3 { actions.refreshNamespaces(contextNamed: "first") }
        #expect(await lister.contexts.count == 1)
        await lister.open()
        try await appEventually { store.clusters[0].namespaces == .listed(["alpha"]) }
        #expect(await lister.contexts.count == 1)
        await actions.shutdownAndWait()
    }

    @Test func aSecondConnectSupersedesAnInFlightListRatherThanRacingIt() async throws {
        let lister = NamespaceTestLister(names: ["alpha"], gated: true)
        let (store, actions, _) = try await connected(lister)
        defer { actions.shutdown() }
        try await appEventually { await lister.contexts.count == 1 }

        actions.connect(contextNamed: "first")
        try await appEventually { await lister.contexts.count == 2 }
        await lister.open()
        try await appEventually { store.clusters[0].namespaces == .listed(["alpha"]) }
        #expect(await lister.cancellations == 1)
        await actions.shutdownAndWait()
    }

    @Test func aListForARedefinedContextIsDiscardedAcrossAReload() async throws {
        let probe = ClusterTestProbe()
        await probe.open()
        let lister = NamespaceTestLister(names: ["alpha"], gated: true)
        let loader = ReloadableClusterLoader(contexts: [try appContext()])
        let store = AppStore()
        let actions = AppActions(
            store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces(),
            configurations: loader, lists: PodActionProbe(), probe: probe, namespaces: lister
        )
        defer { actions.shutdown() }
        await actions.loadConfiguration()
        actions.connect(contextNamed: "first")
        try await appEventually { await lister.contexts.count == 1 }

        // Same name, different server: the in-flight list describes neither the new snapshot nor
        // anything the user can still see.
        await loader.replace(contexts: [try redefinedContext("first")])
        await actions.loadConfiguration()
        await lister.open()
        await actions.shutdownAndWait()
        #expect(store.clusters[0].namespaces == .unknown)
    }

    @Test func anInFlightListIsCancelledAndJoinedByShutdown() async throws {
        let lister = NamespaceTestLister(names: ["alpha"], gated: true)
        let (store, actions, _) = try await connected(lister)
        try await appEventually { await lister.contexts.count == 1 }

        await actions.shutdownAndWait()
        #expect(await lister.cancellations == 1)
        #expect(store.clusters[0].namespaces == .unknown)
    }
}

@MainActor final class TestMonotonicClock {
    private var seconds: TimeInterval = 1_000
    var read: @Sendable () -> TimeInterval {
        { MainActor.assumeIsolated { self.seconds } }
    }

    func advance(_ interval: TimeInterval) { seconds += interval }
}

actor NamespaceTestLister: NamespaceListing {
    private var names: [String]
    private var failure: (any Error)?
    private let gate = AppTestGate()
    private let gated: Bool
    private(set) var contexts: [ResolvedContext] = []
    private(set) var cancellations = 0

    init(names: [String] = [], failure: (any Error)? = nil, gated: Bool = false) {
        self.names = names
        self.failure = failure
        self.gated = gated
    }

    func open() async { await gate.open() }

    func succeed(with names: [String]) {
        self.names = names
        failure = nil
    }

    func namespaces(context: ResolvedContext) async throws -> [String] {
        contexts.append(context)
        if gated {
            do { try await gate.wait() } catch {
                cancellations += 1
                throw error
            }
        }
        try Task.checkCancellation()
        if let failure { throw failure }
        return names
    }
}
