import Foundation
@testable import KubixCore
import KubixRuntime
import Testing

/// Choosing a container is one menu for both kinds of session: it lists what the pod actually
/// declares, opens nothing until a choice is made, and never opens a second session for a container
/// that already has one.
@Suite @MainActor struct SessionMenuTests {
    @Test func logsOfferEveryDeclaredContainerAndOpenNothingUntilOneIsChosen() async throws {
        let transport = LogTestTransport(stream: { _, _ in MemoryByteStream([Data("synthetic\n".utf8)]) })
        let owner = try PodShellTestOwner(transport: transport, logs: LogService { _ in transport })
        owner.actions.openPodLogs(uid: "uid-0")
        try await watchEventually { owner.store.containerPicker != nil }
        let picker = try #require(owner.store.containerPicker)
        #expect(picker.purpose == .logs && picker.pod == "pod-0" && picker.defaultContainer == "web")
        // Every kind, because a log tail can target any of them, each labelled by what it is.
        #expect(picker.items.map(\.name) == ["web", "waiting", "setup", "debugger"])
        #expect(picker.items.map(\.role) == ["Default container", "Container", "Init container", "Ephemeral container"])
        #expect(picker.items.map(\.state) == ["Running", "Unknown", "Running", "Running"])
        #expect(owner.store.logSessions.isEmpty)

        owner.actions.confirmPodLogs(selectionID: picker.id, container: "setup")
        try await watchEventually { owner.store.logSessions.first?.buffer.count == 2 }
        let log = try #require(owner.store.logSessions.first)
        #expect(log.target.container.name == "setup" && log.target.uid == "uid-0")
        #expect(owner.store.containerPicker == nil)
        #expect(owner.store.selectedSession == .logs(log.id))
        #expect(owner.store.openSessions == [.logs(log.id)])
        owner.actions.closeLog(log.id)
        #expect(owner.store.openSessions.isEmpty && owner.store.selectedSession == nil)
        await owner.actions.shutdownAndWait()
    }

    @Test func cancellingTheMenuLeavesNoSessionAndNoPendingChoice() async throws {
        let transport = LogTestTransport()
        let owner = try PodShellTestOwner(transport: transport, logs: LogService { _ in transport })
        owner.actions.openPodLogs(uid: "uid-0")
        try await watchEventually { owner.store.containerPicker != nil }
        let picker = try #require(owner.store.containerPicker)
        owner.actions.cancelPodLogs(selectionID: picker.id)
        #expect(owner.store.containerPicker == nil && owner.store.logSessions.isEmpty)
        // A stale confirmation of a dismissed menu is not a second chance to open it.
        owner.actions.confirmPodLogs(selectionID: picker.id, container: "web")
        #expect(owner.store.logSessions.isEmpty)
        await owner.actions.shutdownAndWait()
    }

    @Test func switchingToAContainerThatIsAlreadyOpenFocusesItInsteadOfOpeningAnother() async throws {
        let transport = LogTestTransport(stream: { _, _ in MemoryByteStream([Data("synthetic\n".utf8)]) })
        let owner = try PodShellTestOwner(transport: transport, logs: LogService { _ in transport })
        owner.actions.openPodLogs(uid: "uid-0", container: "web")
        try await watchEventually { owner.store.logSessions.count == 1 }
        owner.actions.openPodLogs(uid: "uid-0", container: "setup")
        try await watchEventually { owner.store.logSessions.count == 2 }
        let first = try #require(owner.store.logSessions.first { $0.target.container.name == "web" })
        let second = try #require(owner.store.logSessions.first { $0.target.container.name == "setup" })
        #expect(owner.store.openSessions == [.logs(first.id), .logs(second.id)])
        #expect(owner.store.selectedSession == .logs(second.id))

        #expect(owner.actions.hasOpenSession(.logs(second.id), container: "web"))
        owner.actions.openSessionForContainer(.logs(second.id), container: "web")
        #expect(owner.store.logSessions.count == 2 && owner.store.selectedSession == .logs(first.id))
        #expect(!owner.actions.hasOpenSession(.logs(first.id), container: "debugger"))
        await owner.actions.shutdownAndWait()
    }
}
