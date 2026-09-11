import Foundation
@testable import KubixCore
import Testing

@Suite @MainActor struct PodBrowsingActionTests {
    @Test func actionsKeepUIDAndSchemaAndNeverRetargetOrRecreateExistingSurfaces() async throws {
        let auth = AppTestAuth()
        await auth.gate.open()
        let surfaces = AppTestSurfaces()
        let store = AppStore(contexts: [try appContext(), try appContext("second")])
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: surfaces)
        defer { actions.shutdown() }
        let target = try appTarget()
        let session = actions.openShell(target: target)
        try await appEventually { store.execSessions.first?.state == .running }
        let surface = try #require(surfaces.created[session])
        let table = try presentationTable(cells: [#"["zulu"]"#, #"["alpha"]"#])
        let rows = try table.rows.map(PodRow.init)
        actions.applyPodUpdate(.init(rows: rows, columns: table.columnDefinitions, connection: .live))
        actions.selectPod(uid: "uid-0")
        actions.sortPods(.init(column: 0))
        #expect(store.selectedPodUID == "uid-0" && store.podTable.rows.first?.id == "uid-1")
        actions.applyPodUpdate(.init(rows: rows.reversed(), columns: table.columnDefinitions, connection: .live))
        #expect(store.selectedPodUID == "uid-0" && store.podSort?.column == 0)
        actions.setPodFilter("alpha")
        #expect(store.selectedPodUID == nil)
        actions.setPodFilter("")
        #expect(store.selectedPodUID == nil)
        actions.selectPod(uid: "absent")
        #expect(store.selectedPodUID == nil)
        actions.selectPod(uid: "uid-0")
        let replacement = try presentationTable(cells: [#"["zulu"]"#], uidPrefix: "new")
        actions.applyPodUpdate(.init(rows: try replacement.rows.map(PodRow.init), columns: table.columnDefinitions, connection: .live))
        #expect(store.selectedPodUID == nil)
        try actions.selectContext(named: "second")
        actions.setPodWide(true)
        #expect(store.execSessions.first?.target == target)
        #expect(actions.surface(for: session) === surface && surface.closes == 0 && surfaces.created.count == 1)
        await actions.shutdownAndWait()
        #expect(surface.closes == 1)
    }

    @Test func wideAndSchemaChangesRemoveInvalidSortAndClearHiddenSelection() throws {
        let store = AppStore()
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces())
        defer { actions.shutdown() }
        let table = try presentationTable(
            columns: #"[{"name":"Ordinary","type":"string"},{"name":"Wide","type":"string","priority":1}]"#,
            cells: [#"["alpha","match"]"#]
        )
        actions.applyPodUpdate(.init(rows: try table.rows.map(PodRow.init), columns: table.columnDefinitions, connection: .live))
        actions.setPodWide(true)
        actions.sortPods(.init(column: 1))
        actions.setPodFilter("match")
        actions.selectPod(uid: "uid-0")
        actions.setPodWide(false)
        #expect(store.podSort == nil && store.selectedPodUID == nil && store.podTable.state == .filteredEmpty)
        actions.setPodFilter("")
        actions.sortPods(.init(column: 0))
        let changed = try presentationTable(cells: [#"["alpha"]"#])
        actions.applyPodUpdate(.init(rows: try changed.rows.map(PodRow.init), columns: changed.columnDefinitions, connection: .live))
        #expect(store.podSort == nil)
    }

    @Test func draftEditsNeverStartPodsAndACommitListsOnlyWhileBrowsingPods() async throws {
        let probe = PodActionProbe()
        let cluster = ClusterTestProbe()
        await cluster.open()
        let store = AppStore(contexts: [try appContext()])
        let actions = AppActions(
            store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces(),
            pods: probe, probe: cluster
        )
        defer { actions.shutdown() }

        for value in ["k", "known", "bad/input"] { actions.setNamespaceInput(value) }
        #expect(await probe.callbacks.isEmpty)
        #expect(!actions.commitNamespaceInput())
        #expect(store.namespaceDiagnostic != nil && store.selectedNamespace == "first-namespace")
        #expect(await probe.callbacks.isEmpty)

        // Committing a valid namespace on a cluster row is not a request to connect and list.
        actions.setNamespaceInput("known")
        #expect(actions.commitNamespaceInput())
        #expect(store.selectedNamespace == "known" && store.namespaces.contains("known"))
        #expect(await probe.callbacks.isEmpty)
        #expect(store.connection == .idle)

        actions.connect(contextNamed: "first")
        try await appEventually { store.clusters[0].state == .connected }
        actions.selectSidebar(.pods("first"))
        try await appEventually { await probe.callbacks.count == 1 }
        actions.setNamespaceInput("other")
        #expect(actions.commitNamespaceInput())
        try await appEventually { await probe.callbacks.count == 2 }
        #expect(await probe.targets.map(\.namespace) == ["known", "other"])
        await actions.shutdownAndWait()
        #expect(await probe.ended == 2)
    }

    @Test(arguments: [APIError.podAuthentication, .http(code: 401, resource: "pods"), .http(code: 403, resource: "pods")])
    func successfulConfiguredAuthenticationRetriesOnlyAuthFailedDiscovery(_ failure: APIError) async throws {
        let probe = PodActionProbe()
        let auth = AppTestAuth()
        await auth.gate.open()
        let store = AppStore(contexts: [try appContext()])
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces(), pods: probe)
        defer { actions.shutdown() }
        actions.applyPodUpdate(.init(rows: [], columns: nil, connection: .failed(failure)))
        await actions.authenticateSelectedContext()
        if failure.httpCode == 403 {
            #expect(store.connection == .failed(failure))
            #expect(await probe.callbacks.isEmpty)
        } else {
            try await appEventually { await probe.callbacks.count == 1 }
            #expect(store.connection == .connecting)
        }
        #expect(store.execSessions.isEmpty)
        await actions.shutdownAndWait()
    }

    @Test func oldContextAuthenticationCompletionCannotRetryNewContextsFailure() async throws {
        let first = try appContext()
        let auth = AppTestAuth()
        let probe = PodActionProbe()
        let store = AppStore(contexts: [first, try appContext("second")])
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces(), pods: probe)
        defer { actions.shutdown() }
        let work = Task { try await actions.acquireCredentials(context: first) }
        try await appEventually { await auth.acquisitions.count == 1 }
        try actions.selectContext(named: "second")
        actions.refreshPods()
        try await appEventually { await probe.callbacks.count == 1 }
        await probe.emit(.init(rows: [], columns: nil, connection: .failed(.podAuthentication)))
        await auth.gate.open()
        try await work.value
        #expect(store.connection == .failed(.podAuthentication))
        #expect(await probe.callbacks.count == 1)
        await actions.shutdownAndWait()
    }

    @Test(arguments: ["sign-in", "retry"])
    func explicitAuthRecoveryRetriesCommittedNamespaceWithoutCommittingDraft(_ operation: String) async throws {
        let context = try appContext()
        let auth = AppTestAuth()
        await auth.gate.open()
        let probe = PodActionProbe()
        let store = AppStore(contexts: [context])
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces(), pods: probe)
        defer { actions.shutdown() }
        try await appEventually { await auth.subscriberCount == 1 }
        let session = AuthSession(credentialIdentity: try CredentialIdentity(from: context), provider: "synthetic", state: .failed)
        await auth.emit(session)
        try await appEventually { store.authenticationSessions[session.id] != nil }
        actions.applyPodUpdate(.init(rows: [], columns: nil, connection: .failed(.podAuthentication)))
        actions.setNamespaceInput("unfinished-draft")
        if operation == "retry" {
            try await actions.retryAuthentication(operationID: session.id)
        } else {
            await actions.signInSelectedContext()
        }
        try await appEventually { await probe.callbacks.count == 1 }
        #expect(store.selectedNamespace == "first-namespace" && store.namespaceDraft == "unfinished-draft")
        #expect(await probe.targets.count == 1)
        #expect(await probe.targets.first?.context == context)
        #expect(await probe.targets.first?.namespace == "first-namespace")
        #expect(store.connection == .connecting && store.execSessions.isEmpty)
        await actions.shutdownAndWait()
    }

    @Test func failedExplicitAuthenticationDoesNotLoopDiscovery() async throws {
        let auth = AppTestAuth()
        await auth.gate.open()
        await auth.fail(AppTestError.injected)
        let probe = PodActionProbe()
        let store = AppStore(contexts: [try appContext()])
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces(), pods: probe)
        defer { actions.shutdown() }
        actions.applyPodUpdate(.init(rows: [], columns: nil, connection: .failed(.podAuthentication)))
        await actions.authenticateSelectedContext()
        #expect(store.connection == .failed(.podAuthentication) && store.authenticationDiagnostic != nil)
        #expect(await probe.callbacks.isEmpty)
        await actions.shutdownAndWait()
    }
}
