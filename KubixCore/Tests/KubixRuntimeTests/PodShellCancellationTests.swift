import Foundation
@testable import KubixCore
@testable import KubixRuntime
import Testing

@Suite @MainActor struct PodShellCancellationTests {
    enum Change: CaseIterable, Sendable {
        case context, namespace, selectionAwayBack, rowRevision, rowDeleted, rowReplaced, filtered, reload, refresh, rowAwayBack, contextReplacement
    }

    private func change(_ change: Change, owner: PodShellTestOwner) async throws {
        switch change {
        case .context, .contextReplacement: try await changeContext(change, owner: owner)
        case .namespace: try owner.actions.selectNamespace("other")
        case .selectionAwayBack:
            owner.actions.selectPod(uid: "uid-1")
            owner.actions.selectPod(uid: "uid-0")
        case .rowRevision: try owner.changeRow()
        case .rowDeleted: try owner.install(ids: [1])
        case .rowReplaced:
            let json = String(decoding: try podPage(ids: [0]), as: UTF8.self).replacingOccurrences(of: "uid-0", with: "replacement")
            let table = try JSONDecoder().decode(KubernetesTable.self, from: Data(json.utf8))
            owner.actions.applyPodUpdate(.init(rows: try table.rows.map { try PodRow(row: $0) }, columns: table.columnDefinitions, connection: .live))
        case .filtered: owner.actions.setPodFilter("pod-1")
        case .reload: await owner.actions.loadConfiguration()
        case .refresh: owner.actions.refreshPods()
        case .rowAwayBack: try owner.changeRow(); try owner.install()
        }
    }

    private func changeContext(_ change: Change, owner: PodShellTestOwner) async throws {
        if change == .context { try owner.actions.selectContext(named: "second"); return }
        let replacement = try Kubeconfig(
            currentContext: "first", clusters: [.init(name: "replacement", cluster: .init(server: "https://replacement.synthetic.invalid"))],
            contexts: [.init(name: "first", context: .init(cluster: "replacement", namespace: "team"))]
        ).resolve()
        await owner.configuration.replace([replacement])
        await owner.actions.loadConfiguration()
    }

    @Test(arguments: Change.allCases, [true, false])
    func staleResponseOrPickerNeverSpawns(change: Change, response: Bool) async throws {
        let gate = UncooperativeWatchGate()
        let transport = WatchTestTransport { _, _ in
            if response { await gate.wait() }
            return try podDetailsData(running: ["web", "sidecar"])
        }
        let owner = try PodShellTestOwner(transport: transport)
        owner.actions.openPodShell(uid: "uid-0")
        if response { try await watchEventually { await gate.isWaiting } } else {
            try await watchEventually { owner.store.containerPicker != nil }
        }
        let picker = owner.store.containerPicker
        try await self.change(change, owner: owner)
        await gate.open()
        if let picker { owner.actions.confirmPodShell(selectionID: picker.id, container: "web") }
        await owner.actions.shutdownAndWait()
        #expect(owner.store.containerPicker == nil && !owner.store.isLoadingPodDetails)
        #expect(owner.store.execSessions.isEmpty && owner.surfaces.created.isEmpty)
        #expect(await owner.auth.acquisitions.isEmpty)
        #expect(await owner.exec.targets.isEmpty)
    }

    @Test func supersededUncooperativeRequestCannotReplaceNewPickerOrCancelIt() async throws {
        let gate = UncooperativeWatchGate()
        let transport = WatchTestTransport { _, call in
            if call == 1 { await gate.wait(); throw APIError.http(code: 403, resource: "old") }
            return try podDetailsData(running: ["web", "sidecar"], annotation: "sidecar")
        }
        let owner = try PodShellTestOwner(transport: transport)
        owner.actions.openPodShell(uid: "uid-0")
        try await watchEventually { await gate.isWaiting }
        let first = try #require(owner.actions.podShellSelection?.id)
        owner.actions.openPodShell(uid: "uid-0")
        try await watchEventually { owner.store.containerPicker != nil }
        let second = try #require(owner.store.containerPicker)
        await gate.open()
        try await watchEventually { owner.actions.podDetailTasks.isEmpty }
        owner.actions.cancelPodShell(selectionID: first)
        owner.actions.confirmPodShell(selectionID: first, container: "web")
        #expect(owner.store.containerPicker == second && owner.store.podShellDiagnostic == nil)
        owner.actions.cancelPodShell(selectionID: second.id)
        owner.actions.confirmPodShell(selectionID: second.id, container: "sidecar")
        #expect(owner.store.execSessions.isEmpty && owner.store.containerPicker == nil)
        await owner.actions.shutdownAndWait()
    }

    @Test(arguments: [true, false])
    func shutdownOrExplicitCancelDiscardsLateDetails(shutdown: Bool) async throws {
        let gate = UncooperativeWatchGate()
        let owner = try PodShellTestOwner(transport: WatchTestTransport { _, _ in await gate.wait(); return try podDetailsData() })
        owner.actions.openPodShell(uid: "uid-0")
        try await watchEventually { await gate.isWaiting }
        if shutdown { owner.actions.shutdown() } else {
            owner.actions.cancelPodShell(selectionID: try #require(owner.actions.podShellSelection?.id))
        }
        await gate.open()
        await owner.actions.shutdownAndWait()
        #expect(owner.store.execSessions.isEmpty && owner.actions.podDetailTasks.isEmpty)
    }

    @Test(arguments: Change.allCases, [true, false])
    func authAndFinalSurfaceDispatchRetainSelectionGuard(change: Change, authentication: Bool) async throws {
        let gate = UncooperativeWatchGate()
        let auth = PodShellAuth(gate: authentication ? gate : nil)
        let exec = PodShellExec(gate: authentication ? nil : gate)
        let owner = try PodShellTestOwner(
            transport: WatchTestTransport { _, _ in try podDetailsData() }, auth: auth, exec: exec
        )
        owner.actions.openPodShell(uid: "uid-0")
        try await watchEventually { await gate.isWaiting }
        let id = try #require(owner.store.execSessions.first?.id)
        try await self.change(change, owner: owner)
        await gate.open()
        await owner.actions.shutdownAndWait()
        owner.actions.retryShell(id)
        #expect(owner.store.execSessions[0].isClosed && owner.surfaces.created.isEmpty)
        #expect(await exec.targets.count == (authentication ? 0 : 1))
    }

    @Test func watchRowRevisionCancelsPickerThroughActualWatchService() async throws {
        let stream = MemoryByteStream()
        let transport = WatchTestTransport(
            data: { request, _ in
                request.accept == APIRequest.tableAccept ? try podPage() : try podDetailsData(running: ["web", "sidecar"])
            }, stream: { _, _ in stream }
        )
        let owner = try PodShellTestOwner(transport: transport, watch: WatchService(transports: { _ in transport }))
        owner.actions.refreshPods()
        try await watchEventually { owner.store.connection == .live }
        owner.actions.openPodShell(uid: "uid-0")
        try await watchEventually { owner.store.containerPicker != nil }
        let picker = try #require(owner.store.containerPicker)
        let event = String(decoding: try podEvent(), as: UTF8.self).replacingOccurrences(of: "row-0", with: "changed")
        stream.yield(Data(event.utf8))
        try await watchEventually { owner.store.containerPicker == nil }
        owner.actions.confirmPodShell(selectionID: picker.id, container: "web")
        #expect(owner.store.execSessions.isEmpty)
        let requests = await transport.requests
        #expect(requests[0].accept == APIRequest.tableAccept && podQuery(requests[0])["includeObject"] == "Metadata")
        #expect(requests[1].accept == "application/json" && requests[1].query.isEmpty)
        let watches = await transport.streams
        #expect(watches.allSatisfy { $0.accept == APIRequest.tableAccept && podQuery($0)["includeObject"] == "Metadata" })
        await owner.actions.shutdownAndWait()
        #expect(stream.cancelled)
    }

    @Test func execServiceDoesNotOpenSocketAfterLateCancelledTransportFactory() async throws {
        let gate = UncooperativeWatchGate()
        let transport = ExecTestTransport(ExecTestSocket())
        let bridges = try ExecTestBridges(ExecTestBridge())
        let service = ExecService(transports: { _ in await gate.wait(); return transport }, bridges: bridges)
        let capture = ExecStateCapture()
        let work = try execRun(service: service, capture: capture)
        try await watchEventually { await gate.isWaiting }
        work.cancel()
        await gate.open()
        #expect(await work.value == .cancelled)
        #expect(await transport.requests.isEmpty)
        #expect(await bridges.prepared.isEmpty)
        #expect(capture.endpoints.isEmpty)
    }

    /// A second open is another session the user asked for, not a correction of the first: both run,
    /// each with its own surface. What supersession still governs is the pending *request* — the one
    /// details fetch and its menu — never a session that has already been created from an earlier one.
    @Test func asecondOpenLeavesTheStillAuthenticatingSessionRunningAlongsideIt() async throws {
        let gate = UncooperativeWatchGate()
        let owner = try PodShellTestOwner(
            transport: WatchTestTransport { _, _ in try podDetailsData() }, auth: PodShellAuth(gate: gate)
        )
        owner.actions.openPodShell(uid: "uid-0")
        try await watchEventually { await gate.isWaiting }
        let id = try #require(owner.store.execSessions.first?.id)
        owner.actions.openPodShell(uid: "uid-0")
        try await watchEventually { owner.store.execSessions.count == 2 && owner.store.execSessions[1].state == .running }
        await gate.open()
        try await watchEventually { owner.store.execSessions.first?.state == .running }
        #expect(owner.store.execSessions.allSatisfy { !$0.isClosed })
        #expect(owner.store.openSessions.count == 2)
        #expect(await owner.exec.targets.count == 2)
        #expect(owner.surfaces.created.count == 2 && owner.surfaces.created[id] != nil)
        // Both are running, so both have relinquished their selection guard and a scope change
        // leaves them alone — a shell outlives the row it was started from.
        owner.actions.selectPod(uid: "uid-1")
        #expect(owner.store.execSessions.allSatisfy { !$0.isClosed } && owner.store.openSessions.count == 2)
        await owner.actions.shutdownAndWait()
    }

    @Test func reloadInProgressRejectsNewRowActionsBeforeReplacementConfigurationArrives() async throws {
        let transport = WatchTestTransport { _, _ in try podDetailsData() }
        let owner = try PodShellTestOwner(transport: transport)
        let gate = UncooperativeWatchGate()
        await owner.configuration.block(on: gate)
        let work = Task { await owner.actions.loadConfiguration() }
        try await watchEventually { await gate.isWaiting }
        owner.actions.openPodShell(uid: "uid-0")
        #expect(owner.store.podShellDiagnostic?.contains("configuration reload") == true)
        #expect(await transport.requests.isEmpty)
        await gate.open()
        await work.value
        #expect(owner.store.execSessions.isEmpty && !owner.store.isLoadingConfiguration)
        await owner.actions.shutdownAndWait()
    }
}
