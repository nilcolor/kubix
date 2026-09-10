import Foundation
import KubixCore
import Testing

@Suite @MainActor struct AppActionsRaceTests {
    @Test func successfulSaveSurvivesQueuedFailureWithoutOverwritingNewerDraft() async throws {
        let gate = AppTestGate()
        let auth = AppTestAuth(settingsGate: gate, settingsFailures: [2])
        let store = AppStore()
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces())
        defer { actions.shutdown() }
        let good = AuthSettings(searchDirectories: ["/working"])
        let first = Task { try await actions.updateAuthSettings(good) }
        try await appEventually { await auth.settings.count == 1 }
        let second = Task { try await actions.updateAuthSettings(AuthSettings(searchDirectories: ["/failing"])) }
        var draft = store.settingsDraft
        draft.searchDirectories = "/unsaved-draft"
        actions.setSettingsDraft(draft)
        await gate.open()
        try await first.value
        await #expect(throws: AppTestError.injected) { try await second.value }
        #expect(store.authSettings == good)
        #expect(store.settingsDraft == draft)
        let later = AuthSettings(searchDirectories: ["/later"])
        try await actions.updateAuthSettings(later)
        #expect(store.authSettings == later && store.settingsDraft.searchDirectories == "/later")
    }

    @Test func successfulSaveCannotDiscardDraftEditedWhilePersistenceIsPending() async throws {
        let gate = AppTestGate()
        let auth = AppTestAuth(settingsGate: gate)
        let store = AppStore()
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces())
        defer { actions.shutdown() }
        let settings = AuthSettings(searchDirectories: ["/persisted"])
        let work = Task { try await actions.updateAuthSettings(settings) }
        try await appEventually { await gate.count == 1 }
        var draft = store.settingsDraft
        draft.searchDirectories = "/newer-draft"
        actions.setSettingsDraft(draft)
        await gate.open()
        try await work.value
        #expect(store.authSettings == settings && store.settingsDraft == draft)
    }

    @Test func saveCompletionCannotReplaceNewContextsDraftOrDiagnostic() async throws {
        let gate = AppTestGate()
        let auth = AppTestAuth(settingsGate: gate)
        let store = AppStore(contexts: [try appContext(), try appContext("second")])
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces())
        defer { actions.shutdown() }
        var original = store.settingsDraft
        original.searchDirectories = "/persisted"
        actions.setSettingsDraft(original)
        let work = Task { await actions.saveAuthSettings() }
        try await appEventually { await gate.count == 1 }
        try actions.selectContext(named: "second")
        let newDraft = store.settingsDraft
        await gate.open()
        await work.value
        #expect(store.authSettings.searchDirectories == ["/persisted"])
        #expect(store.settingsDraft == newDraft && store.settingsDiagnostic == nil)
    }

    @Test func settingsSavesAreSerializedAndOnlyLatestSnapshotBecomesCurrent() async throws {
        let gate = AppTestGate()
        let auth = AppTestAuth(settingsGate: gate)
        let store = AppStore()
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces())
        defer { actions.shutdown() }
        let old = AuthSettings(searchDirectories: ["/old"])
        let latest = AuthSettings(searchDirectories: ["/latest"])
        let first = Task { try await actions.updateAuthSettings(old) }
        try await appEventually { await auth.settings.count == 1 }
        let second = Task { try await actions.updateAuthSettings(latest) }
        await Task.yield()
        #expect(await auth.settings == [old])
        await gate.open()
        try await first.value
        try await second.value
        #expect(await auth.settings == [old, latest])
        #expect(store.authSettings == latest)
    }

    @Test func oldSignInCompletionCannotClearNewerDiagnostic() async throws {
        let auth = AppTestAuth()
        let oldGate = AppTestGate()
        let latestGate = AppTestGate()
        await auth.configureSignIn("old", gate: oldGate)
        await auth.configureSignIn("latest", gate: latestGate, failure: .missingAWSProfile)
        let store = AppStore()
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces())
        defer { actions.shutdown() }
        let first = Task { try await actions.signIn(context: appContext("old")) }
        try await appEventually { await oldGate.count == 1 }
        let second = Task { try await actions.signIn(context: appContext("latest")) }
        try await appEventually { await latestGate.count == 1 }
        await latestGate.open()
        await #expect(throws: AuthenticationError.missingAWSProfile) { try await second.value }
        await oldGate.open()
        try await first.value
        #expect(store.authenticationDiagnostic == AuthenticationError.missingAWSProfile.errorDescription)
    }

    @Test func shutdownCancelsAllQueuedSettingsSaves() async throws {
        let gate = AppTestGate()
        let auth = AppTestAuth(settingsGate: gate)
        let store = AppStore()
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces())
        let first = Task { try await actions.updateAuthSettings(AuthSettings(searchDirectories: ["/old"])) }
        try await appEventually { await gate.count == 1 }
        let second = Task { try await actions.updateAuthSettings(AuthSettings(searchDirectories: ["/latest"])) }
        await Task.yield()
        actions.shutdown()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(await gate.count == 0)
        #expect(store.authSettings == AuthSettings())
    }

    @Test func shutdownCancelsOwnedAuthenticationWaiterAndProgressSubscription() async throws {
        let auth = AppTestAuth()
        let store = AppStore()
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces())
        let login = Task { try await actions.signIn(context: appContext()) }
        try await appEventually {
            let subscribers = await auth.subscriberCount
            return await auth.gate.count == 1 && subscribers == 1
        }
        actions.shutdown()
        actions.shutdown()
        await #expect(throws: CancellationError.self) { try await login.value }
        try await appEventually {
            let subscribers = await auth.subscriberCount
            return await auth.gate.count == 0 && subscribers == 0
        }
        #expect(store.authenticationDiagnostic == nil)
        #expect(store.authenticationSessions.isEmpty)
        #expect(await auth.cancellations.isEmpty)
        await #expect(throws: CancellationError.self) { try await actions.signIn(context: appContext()) }
        await #expect(throws: CancellationError.self) { try await actions.retryAuthentication(operationID: UUID()) }
    }
}
