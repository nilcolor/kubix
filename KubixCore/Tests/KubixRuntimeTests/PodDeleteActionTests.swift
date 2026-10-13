import Foundation
@testable import KubixCore
import KubixRuntime
import Testing

@Suite @MainActor struct PodDeleteActionTests {
    @Test func menuAsksFirstAndConfirmDeletesTheClickedRow() async throws {
        let transport = WatchTestTransport { _, _ in Data("{}".utf8) }
        let owner = try PodShellTestOwner(transport: transport)
        owner.actions.selectRow(uid: "uid-0")
        let menu = try #require(owner.actions.podDeleteMenuAction(uid: "uid-1"))
        menu()
        let dialog = try #require(owner.store.podDeletion)
        #expect(dialog.pod == "pod-1" && dialog.namespace == "team" && dialog.context == "first")
        #expect(owner.store.selectedRowUID == "uid-1")
        #expect(await transport.requests.isEmpty)
        owner.actions.confirmPodDeletion(id: dialog.id)
        #expect(owner.store.podDeletion == nil)
        try await watchEventually { await transport.requests.count == 1 }
        let request = try #require(await transport.requests.first)
        #expect(request.method == "DELETE" && request.path == ["api", "v1", "namespaces", "team", "pods", "pod-1"])
        #expect(try deletePreconditionUID(request.body) == "uid-1")
        owner.actions.confirmPodDeletion(id: dialog.id)
        await owner.actions.shutdownAndWait()
        #expect(await transport.requests.count == 1)
        #expect(owner.store.podDeleteDiagnostic == nil)
    }

    @Test func cancelAndForeignConfirmationsSendNothing() async throws {
        let transport = WatchTestTransport { _, _ in Data("{}".utf8) }
        let owner = try PodShellTestOwner(transport: transport)
        owner.actions.requestPodDeletion(uid: "uid-0")
        let dialog = try #require(owner.store.podDeletion)
        owner.actions.confirmPodDeletion(id: UUID())
        #expect(owner.store.podDeletion == dialog)
        owner.actions.cancelPodDeletion(id: dialog.id)
        owner.actions.confirmPodDeletion(id: dialog.id)
        #expect(owner.store.podDeletion == nil)
        await owner.actions.shutdownAndWait()
        #expect(await transport.requests.isEmpty)
    }

    /// SwiftUI can report the dialog closed before it runs the Delete button that closed it.
    @Test func dialogClosingBeforeItsButtonStillConfirms() async throws {
        let transport = WatchTestTransport { _, _ in Data("{}".utf8) }
        let owner = try PodShellTestOwner(transport: transport)
        owner.actions.requestPodDeletion(uid: "uid-0")
        let dialog = try #require(owner.store.podDeletion)
        owner.actions.podDeletionDialogClosed()
        owner.actions.confirmPodDeletion(id: dialog.id)
        try await watchEventually { await transport.requests.count == 1 }
        await owner.actions.shutdownAndWait()
    }

    /// A crash-looping pod is the one most likely to be deleted, and its row changes every few seconds.
    @Test func theRowChangingUnderTheDialogKeepsIt() async throws {
        let transport = WatchTestTransport { _, _ in Data("{}".utf8) }
        let owner = try PodShellTestOwner(transport: transport)
        owner.actions.requestPodDeletion(uid: "uid-0")
        let dialog = try #require(owner.store.podDeletion)
        try owner.changeRow()
        #expect(owner.store.podDeletion == dialog)
        owner.actions.confirmPodDeletion(id: dialog.id)
        try await watchEventually { await transport.requests.count == 1 }
        await owner.actions.shutdownAndWait()
    }

    @Test func aNamespaceChangeDismissesTheDialogAndSendsNothing() async throws {
        let transport = WatchTestTransport { _, _ in Data("{}".utf8) }
        let owner = try PodShellTestOwner(transport: transport)
        owner.actions.requestPodDeletion(uid: "uid-0")
        let dialog = try #require(owner.store.podDeletion)
        owner.actions.setNamespaceInput("other")
        #expect(owner.actions.commitNamespaceInput())
        #expect(owner.store.podDeletion == nil)
        owner.actions.confirmPodDeletion(id: dialog.id)
        await owner.actions.shutdownAndWait()
        #expect(await transport.requests.isEmpty)
    }

    @Test(arguments: [(409, "replaced"), (403, "delete-pods permission"), (404, "already gone")])
    func refusalsExplainThemselves(_ code: Int, _ phrase: String) async throws {
        let transport = WatchTestTransport { request, _ in
            throw APIError.response(code: code, body: Data(), resource: request.resourceContext)
        }
        let owner = try PodShellTestOwner(transport: transport)
        owner.actions.requestPodDeletion(uid: "uid-0")
        owner.actions.confirmPodDeletion(id: try #require(owner.store.podDeletion).id)
        try await watchEventually { owner.store.podDeleteDiagnostic != nil }
        let message = try #require(owner.store.podDeleteDiagnostic)
        #expect(message.contains("pod-0") && message.contains(phrase))
        owner.actions.dismissPodDiagnostics()
        #expect(owner.store.podDeleteDiagnostic == nil)
        await owner.actions.shutdownAndWait()
    }

    @Test func shutdownCancelsAndJoinsADeleteInFlight() async throws {
        let gate = UncooperativeWatchGate()
        let transport = WatchTestTransport { _, _ in
            await gate.wait()
            try Task.checkCancellation()
            return Data("{}".utf8)
        }
        let owner = try PodShellTestOwner(transport: transport)
        owner.actions.requestPodDeletion(uid: "uid-0")
        owner.actions.confirmPodDeletion(id: try #require(owner.store.podDeletion).id)
        try await watchEventually { await gate.isWaiting }
        let shutdown = Task { await owner.actions.shutdownAndWait() }
        try await watchEventually { owner.actions.podDeleteTasks.values.allSatisfy(\.isCancelled) }
        await gate.open()
        await shutdown.value
        #expect(owner.actions.podDeleteTasks.isEmpty)
        #expect(owner.store.podDeleteDiagnostic == nil)
    }

    @Test func deploymentRowsOfferNoDelete() async throws {
        let owner = try PodShellTestOwner(transport: WatchTestTransport())
        owner.actions.clearList(.deployments)
        #expect(owner.actions.podDeleteMenuAction(uid: "uid-0") == nil)
        await owner.actions.shutdownAndWait()
    }
}
