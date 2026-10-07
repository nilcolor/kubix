import Foundation
@testable import KubixCore
import KubixRuntime
import Testing

@Suite @MainActor struct PodShellActionTests {
    @Test func returnUsesCommittedNamespaceAndMetadataNotDisplayCells() async throws {
        let transport = WatchTestTransport { _, _ in try podDetailsData() }
        let owner = try PodShellTestOwner(transport: transport)
        owner.actions.setNamespaceInput("unfinished")
        owner.actions.selectRow(uid: "uid-0")
        owner.actions.openPodShell()
        try await watchEventually { owner.store.execSessions.first?.state == .running }
        let target = try #require(owner.store.execSessions.first?.target)
        #expect(target.namespace == "team" && target.pod == "pod-0" && target.container == "web")
        #expect(owner.store.selectedNamespace == "team" && owner.store.namespaceDraft == "unfinished")
        #expect(await transport.requests.first?.accept == "application/json")
        #expect(await owner.auth.acquisitions == [target.context])
        await owner.actions.shutdownAndWait()
        #expect(owner.surfaces.created.values.allSatisfy { $0.frees == 1 })
    }

    @Test func clickedMenuRowNotPriorSelectionAndStaleMenuDoesNothing() async throws {
        let transport = WatchTestTransport { request, _ in
            let name = request.path.last ?? ""
            return try podDetailsData(uid: name == "pod-1" ? "uid-1" : "uid-0", name: name)
        }
        let owner = try PodShellTestOwner(transport: transport)
        owner.actions.selectRow(uid: "uid-0")
        let menu = owner.actions.podShellMenuAction(uid: "uid-1")
        menu()
        try await watchEventually { owner.store.execSessions.first?.state == .running }
        #expect(owner.store.execSessions.first?.target.pod == "pod-1")
        let stale = owner.actions.podShellMenuAction(uid: "uid-0")
        owner.actions.selectRow(uid: "uid-1")
        owner.actions.selectRow(uid: "uid-0")
        stale()
        #expect(await transport.requests.count == 1)
        let updated = owner.actions.podShellMenuAction(uid: "uid-0")
        try owner.changeRow()
        updated()
        #expect(await transport.requests.count == 1)
        await owner.actions.shutdownAndWait()
    }

    @Test func multipleCandidatesRequirePickerAndRejectInvalidOrRepeatedConfirmation() async throws {
        let transport = WatchTestTransport { _, _ in try podDetailsData(running: ["web", "sidecar"], annotation: "sidecar") }
        let owner = try PodShellTestOwner(transport: transport)
        owner.actions.openPodShell(uid: "uid-0")
        try await watchEventually { owner.store.containerPicker != nil }
        let picker = try #require(owner.store.containerPicker)
        #expect(picker.containers == ["web", "sidecar"] && picker.defaultContainer == "sidecar")
        #expect(owner.store.execSessions.isEmpty)
        #expect(await owner.auth.acquisitions.isEmpty)
        owner.actions.confirmPodShell(selectionID: UUID(), container: "sidecar")
        owner.actions.confirmPodShell(selectionID: picker.id, container: "setup")
        #expect(owner.store.execSessions.isEmpty && owner.store.containerPicker == picker)
        owner.actions.confirmPodShell(selectionID: picker.id, container: "sidecar")
        owner.actions.confirmPodShell(selectionID: picker.id, container: "web")
        try await watchEventually { owner.store.execSessions.first?.state == .running }
        #expect(owner.store.execSessions.count == 1 && owner.store.execSessions[0].target.container == "sidecar")
        await owner.actions.shutdownAndWait()
    }

    @Test func noReadyContainerExplainsInsteadOfStartingInitOrEphemeralExec() async throws {
        let transport = WatchTestTransport { _, _ in try podDetailsData(running: [], annotation: "setup") }
        let owner = try PodShellTestOwner(transport: transport)
        owner.actions.openPodShell(uid: "uid-0")
        try await watchEventually { owner.store.podShellDiagnostic != nil }
        #expect(owner.store.podShellDiagnostic?.contains("running regular") == true)
        #expect(owner.store.containerPicker == nil && owner.store.execSessions.isEmpty)
        #expect(await owner.auth.acquisitions.isEmpty)
        await owner.actions.shutdownAndWait()
    }

    @Test(arguments: [403, 404, 409, 500])
    func detailFailureIsVisibleAndNeverAllocatesSession(_ code: Int) async throws {
        let transport = WatchTestTransport { _, _ in
            if code == 409 { return try podDetailsData(uid: "replacement") }
            throw APIError.http(code: code, resource: "pods")
        }
        let owner = try PodShellTestOwner(transport: transport)
        owner.actions.openPodShell(uid: "uid-0")
        try await watchEventually { owner.store.podShellDiagnostic != nil }
        let diagnostic = owner.store.podShellDiagnostic ?? ""
        #expect(diagnostic.contains(code == 403 ? "get-pods" : code == 404 ? "deleted" : code == 409 ? "UID changed" : "HTTP 500"))
        #expect(!owner.store.isLoadingPodDetails && owner.store.execSessions.isEmpty)
        #expect(await owner.exec.targets.isEmpty)
        await owner.actions.shutdownAndWait()
    }

    @Test func activeSessionsSurviveSelectionChangesAndFreeOnlyOnce() async throws {
        let owner = try PodShellTestOwner(transport: WatchTestTransport { _, _ in try podDetailsData() })
        owner.actions.openPodShell(uid: "uid-0")
        try await watchEventually { owner.store.execSessions.first?.state == .running }
        let session = try #require(owner.store.execSessions.first)
        let surface = owner.actions.surface(for: session.id)
        try owner.actions.selectContext(named: "second")
        owner.actions.setListFilter("missing")
        #expect(owner.store.execSessions[0].target == session.target && owner.store.execSessions[0].state == .running)
        #expect(owner.actions.surface(for: session.id) === surface)
        #expect(owner.surfaces.created.values.allSatisfy { $0.frees == 0 })
        await owner.actions.shutdownAndWait()
        await owner.actions.shutdownAndWait()
        #expect(owner.surfaces.created.values.allSatisfy { $0.frees == 1 })
    }

    @Test func authenticationFailureCanRetryOnlyWhileOriginalSelectionIsValid() async throws {
        let owner = try PodShellTestOwner(transport: WatchTestTransport { _, _ in try podDetailsData() })
        await owner.auth.setFailure(true)
        owner.actions.openPodShell(uid: "uid-0")
        try await watchEventually { owner.store.execSessions.first?.state.isTerminal == true }
        let id = try #require(owner.store.execSessions.first?.id)
        #expect(owner.surfaces.created.isEmpty)
        await owner.auth.setFailure(false)
        owner.actions.retryShell(id)
        try await watchEventually { owner.store.execSessions.first?.state == .running }
        #expect(owner.store.execSessions.first?.id == id)
        await owner.actions.shutdownAndWait()
    }

    @Test func unchangedSelectionAndPresentationEditsKeepPickerButOldRetryCannotReturnAfterRowChange() async throws {
        let owner = try PodShellTestOwner(transport: WatchTestTransport { _, _ in try podDetailsData(running: ["web", "sidecar"]) })
        owner.actions.openPodShell(uid: "uid-0")
        try await watchEventually { owner.store.containerPicker != nil }
        let picker = try #require(owner.store.containerPicker)
        owner.actions.selectRow(uid: "uid-0")
        owner.actions.setNamespaceInput("unfinished")
        owner.actions.sortList(.init(column: 0, ascending: false))
        owner.actions.setListWide(true)
        owner.actions.setListFilter("pod-0")
        try owner.install()
        #expect(owner.store.containerPicker == picker)
        await owner.auth.setFailure(true)
        owner.actions.confirmPodShell(selectionID: picker.id, container: "web")
        try await watchEventually { owner.store.execSessions.first?.state.isTerminal == true }
        let id = try #require(owner.store.execSessions.first?.id)
        try owner.changeRow()
        await owner.auth.setFailure(false)
        owner.actions.retryShell(id)
        #expect(owner.store.execSessions.first?.isClosed == true && owner.surfaces.created.isEmpty)
        #expect(await owner.auth.acquisitions.count == 1)
        await owner.actions.shutdownAndWait()
    }

    @Test(arguments: [true, false])
    func cancelledOrFailedDetailAuthenticationIsVisible(cancelled: Bool) async throws {
        let owner = try PodShellTestOwner(transport: WatchTestTransport { _, _ in
            if cancelled { throw CancellationError() }
            throw AuthenticationError.settingsUnavailable
        })
        owner.actions.openPodShell(uid: "uid-0")
        try await watchEventually { owner.store.podShellDiagnostic != nil }
        #expect(owner.store.podShellDiagnostic == (cancelled ? "Authentication was cancelled." : AuthenticationError.settingsUnavailable.errorDescription))
        #expect(owner.store.execSessions.isEmpty && !owner.store.isLoadingPodDetails)
        await owner.actions.shutdownAndWait()
    }
}
