import Foundation
import KubixCore
import Observation
import Testing

@Suite @MainActor struct AppStoreTests {
    @Test func selectionIsObservableAndDoesNotRebindExistingTargets() async throws {
        let first = try appTarget()
        let second = try appContext("second")
        let store = AppStore(contexts: [first.context, second])
        let auth = AppTestAuth()
        let exec = AppTestExec()
        let surfaces = AppTestSurfaces()
        let actions = AppActions(store: store, exec: exec, authentication: auth, surfaces: surfaces)
        defer { actions.shutdown() }
        let changed = ObservationFlag()
        withObservationTracking { _ = store.selectedContext } onChange: { changed.mark() }
        let id = actions.openShell(target: first)
        try actions.selectContext(named: "second")
        try actions.selectNamespace("known-without-list-permission")
        #expect(changed.value)
        #expect(store.selectedContext == second)
        #expect(store.namespaces == ["second-namespace", "known-without-list-permission"])
        #expect(store.execSessions[0].target == first)
        #expect(store.execSessions[0].id == id)
        #expect(surfaces.created.isEmpty)
        #expect(await exec.runs.isEmpty)
        await auth.gate.open()
        try await appEventually { store.execSessions[0].state == .running }
        #expect(await auth.acquisitions == [first.context])
        #expect(await exec.runs[id]?.target == first)
        #expect(surfaces.created.count == 1)
        #expect(throws: KubeconfigError.unknownContext) { try actions.selectContext(named: "absent") }
        #expect(throws: APIError.invalidRequest) { try actions.selectNamespace("") }
        #expect(store.selectedContext == second)
        actions.closeShell(id)
        actions.closeShell(id)
        #expect(surfaces.created[id]?.closes == 1)
        try await appEventually { await exec.ended.contains(id) }
    }

    @Test func closingOneAuthWaiterLeavesOtherShellAndSharedSignInAlive() async throws {
        let target = try appTarget()
        let store = AppStore()
        let auth = AppTestAuth()
        let exec = AppTestExec()
        let surfaces = AppTestSurfaces()
        let actions = AppActions(store: store, exec: exec, authentication: auth, surfaces: surfaces)
        defer { actions.shutdown() }
        let login = Task { try await actions.signIn(context: target.context) }
        let closed = actions.openShell(target: target)
        let survivor = actions.openShell(target: target)
        try await appEventually { await auth.gate.count == 3 }
        actions.closeShell(closed)
        try await appEventually { await auth.gate.count == 2 }
        #expect(await auth.cancellations.isEmpty)
        #expect(await exec.runs.isEmpty)
        await auth.gate.open()
        try await login.value
        try await appEventually { surfaces.created[survivor] != nil }
        #expect(surfaces.created[closed] == nil)
        #expect(store.execSessions[0].state == .finished(.cancelled))
        #expect(await auth.signIns.count == 1)
    }

    @Test func progressIsTransientCancelClearsInstructionsAndRejectsStaleSnapshots() async throws {
        let auth = AppTestAuth()
        let store = AppStore()
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces())
        try await appEventually { await auth.subscriberCount == 1 }
        var session = try AuthSession(credentialIdentity: CredentialIdentity(from: appContext()), provider: "Synthetic")
        session.append("https://synthetic.invalid/authorize DEVICE-CODE")
        await auth.emit(session)
        try await appEventually { store.authenticationSessions[session.id]?.instructions == session.instructions }
        #expect(store.authenticationSessions[session.id]?.authorizationURL?.scheme == "https")
        await actions.cancelAuthentication(operationID: session.id)
        #expect(store.authenticationSessions[session.id]?.instructions.isEmpty == true)
        await auth.emit(session)
        try await actions.retryAuthentication(operationID: session.id)
        #expect(await auth.retries == [session.id])
        #expect(store.authenticationSessions[session.id]?.state == .cancelled)
        let settings = AuthSettings(searchDirectories: ["/synthetic/tools"])
        try await actions.updateAuthSettings(settings)
        #expect(store.authSettings == settings)
        #expect(await auth.settings == [settings])
        await #expect(throws: AuthenticationError.invalidSettings) {
            try await actions.updateAuthSettings(AuthSettings(searchDirectories: ["relative"]))
        }
        #expect(store.authSettings == settings)
        actions.shutdown()
        try await appEventually { await auth.subscriberCount == 0 }
        #expect(store.authenticationSessions.isEmpty)
    }

    @Test func successfulAndFailedProgressClearInstructionsButKeepSanitizedDiagnostic() async throws {
        let auth = AppTestAuth()
        let store = AppStore()
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces())
        defer { actions.shutdown() }
        try await appEventually { await auth.subscriberCount == 1 }
        for state in [AuthSession.State.succeeded, .failed] {
            var session = try AuthSession(credentialIdentity: CredentialIdentity(from: appContext()), provider: "Synthetic")
            session.append("SYNTHETIC-INSTRUCTION")
            await auth.emit(session)
            session.transition(to: state, diagnostic: state == .failed ? "Configured plugin failed." : nil)
            await auth.emit(session)
            try await appEventually { store.authenticationSessions[session.id]?.state == state }
            #expect(store.authenticationSessions[session.id]?.instructions.isEmpty == true)
            #expect(store.authenticationSessions[session.id]?.diagnostic == session.diagnostic)
        }
    }

    @Test func completedAuthCardsCoalesceWithoutHidingActiveOperationsOrOtherFailures() async throws {
        let auth = AppTestAuth()
        let store = AppStore()
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces())
        defer { actions.shutdown() }
        try await appEventually { await auth.subscriberCount == 1 }
        let identity = try CredentialIdentity(from: appContext())
        let first = AuthSession(credentialIdentity: identity, provider: "Synthetic", state: .succeeded)
        var active = AuthSession(credentialIdentity: identity, provider: "Synthetic")
        let replacement = AuthSession(credentialIdentity: identity, provider: "Synthetic", state: .succeeded)
        var unrelated = try AuthSession(credentialIdentity: CredentialIdentity(from: appContext("other")), provider: "Synthetic")
        unrelated.transition(to: .failed, diagnostic: "Configured plugin failed.")
        for session in [first, active, replacement, unrelated] { await auth.emit(session) }
        try await appEventually { store.authenticationSessions.count == 4 }
        #expect(store.visibleAuthenticationSessions.map(\.id) == [active.id, replacement.id, unrelated.id])
        #expect(store.visibleAuthenticationSessions.last?.diagnostic == "Configured plugin failed.")
        let stale = AuthSession(id: first.id, credentialIdentity: identity, provider: "Synthetic")
        await auth.emit(stale)
        active.append("SYNTHETIC-PROGRESS")
        await auth.emit(active)
        try await appEventually { store.authenticationSessions[active.id]?.instructions == active.instructions }
        #expect(store.authenticationSessions[first.id]?.state == .succeeded)
        #expect(store.visibleAuthenticationSessions.map(\.id) == [active.id, replacement.id, unrelated.id])
        var latest = AuthSession(credentialIdentity: identity, provider: "Synthetic")
        latest.transition(to: .failed, diagnostic: "New authentication failure.")
        await auth.emit(latest)
        try await appEventually { store.authenticationSessions[latest.id] != nil }
        #expect(store.visibleAuthenticationSessions.map(\.id) == [active.id, unrelated.id, latest.id])
        #expect(store.visibleAuthenticationSessions.last?.diagnostic == "New authentication failure.")
        actions.shutdown()
        #expect(store.visibleAuthenticationSessions.isEmpty)
    }

    @Test func boundedAuthHistoryRetainsLatestCompletedStatus() async throws {
        let auth = AppTestAuth()
        let store = AppStore()
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces())
        defer { actions.shutdown() }
        try await appEventually { await auth.subscriberCount == 1 }
        let identity = try CredentialIdentity(from: appContext())
        let sessions = (0..<129).map { _ in AuthSession(credentialIdentity: identity, provider: "Synthetic", state: .succeeded) }
        for session in sessions { await auth.emit(session) }
        try await appEventually { store.authenticationSessions[sessions[128].id] != nil }
        #expect(store.authenticationSessions.count == 128)
        #expect(store.authenticationSessions[sessions[0].id] == nil)
        #expect(store.visibleAuthenticationSessions.map(\.id) == [sessions[128].id])
    }

    @Test func authFailureCanRetrySameIDWithoutAllocatingAnEarlySurface() async throws {
        let auth = AppTestAuth()
        await auth.fail(AuthenticationError.materialUnavailable)
        await auth.gate.open()
        let exec = AppTestExec()
        let surfaces = AppTestSurfaces()
        let store = AppStore()
        let actions = AppActions(store: store, exec: exec, authentication: auth, surfaces: surfaces)
        defer { actions.shutdown() }
        let id = actions.openShell(target: try appTarget())
        try await appEventually { store.execSessions[0].state.isTerminal }
        #expect(surfaces.created.isEmpty)
        #expect(await exec.runs.isEmpty)
        #expect(store.execSessions[0].state == .finished(.failed(.authentication(AuthenticationError.materialUnavailable.errorDescription!))))
        await auth.fail(nil)
        actions.retryShell(id)
        try await appEventually { store.execSessions[0].state == .running }
        #expect(store.execSessions.count == 1)
        #expect(store.execSessions[0].id == id)
        #expect(await auth.acquisitions.count == 2)
    }

    @Test func remoteFailureSurvivesChildCallbackAndClose() async throws {
        let auth = AppTestAuth()
        await auth.gate.open()
        let exec = AppTestExec()
        let surfaces = AppTestSurfaces()
        let store = AppStore()
        let actions = AppActions(store: store, exec: exec, authentication: auth, surfaces: surfaces)
        defer { actions.shutdown() }
        let id = actions.openShell(target: try appTarget())
        try await appEventually { await exec.runs[id]?.continuation != nil }
        let failure = ExecSessionResult.failed(.api(.http(code: 403, resource: "pods/exec")))
        await exec.complete(id, failure)
        await actions.childTerminated(id)
        actions.closeShell(id)
        await exec.update(id, .finished(.exited(code: 0)))
        #expect(store.execSessions[0].state == .finished(failure))
        #expect(surfaces.created[id]?.closes == 1)
        #expect(await exec.children.isEmpty)
    }

    @Test func lateReadyAndUpdatesCannotResurrectClosedSession() async throws {
        let auth = AppTestAuth()
        await auth.gate.open()
        let exec = AppTestExec(deferredReady: true)
        let store = AppStore()
        let surfaces = AppTestSurfaces()
        let actions = AppActions(store: store, exec: exec, authentication: auth, surfaces: surfaces)
        defer { actions.shutdown() }
        let id = actions.openShell(target: try appTarget())
        try await appEventually { await exec.runs[id]?.continuation != nil }
        actions.closeShell(id)
        await #expect(throws: CancellationError.self) { try await exec.makeReady(id) }
        await exec.complete(id, .exited(code: 0))
        try await appEventually { await exec.ended.contains(id) }
        #expect(surfaces.created.isEmpty)
        #expect(store.execSessions[0].state == .finished(.cancelled))
    }

    @Test func childFirstAndSurfaceFactoryFailureAreVisible() async throws {
        let auth = AppTestAuth()
        await auth.gate.open()
        let exec = AppTestExec()
        let store = AppStore()
        let surfaces = AppTestSurfaces()
        let actions = AppActions(store: store, exec: exec, authentication: auth, surfaces: surfaces)
        defer { actions.shutdown() }
        let id = actions.openShell(target: try appTarget())
        try await appEventually { await exec.runs[id]?.continuation != nil }
        await actions.childTerminated(id)
        #expect(store.execSessions[0].state == .finished(.failed(.childTerminated)))
        surfaces.failure = true
        _ = actions.openShell(target: try appTarget())
        try await appEventually { store.execSessions[1].state.isTerminal }
        #expect(store.execSessions[1].state == .finished(.failed(.surface)))
    }
}

private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    var value: Bool { lock.withLock { changed } }
    func mark() { lock.withLock { changed = true } }
}
