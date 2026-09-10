import Foundation
import KubixCore
import Testing

@Suite @MainActor struct AppActionsRaceTests {
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
