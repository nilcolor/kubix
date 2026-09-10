import Foundation
@testable import KubixCore
import KubixRuntime
import Testing

@Test @MainActor func queuedPersistenceFailureKeepsLastSuccessfulRuntimeAndUISettings() async throws {
    let persistence = GatedSettingsStore()
    let resolver = PluginResolver(environment: [:], store: persistence, shell: FixedShell(path: "/tools"), files: Executables())
    let provider = CredentialProvider(resolver: resolver, runner: CredentialRunner(process: FakeProcess()))
    let authentication = AuthenticationService(provider: provider)
    let context = try runtimeContext()
    let store = AppStore(contexts: [context])
    let actions = AppActions(store: store, exec: PodShellExec(), authentication: authentication, surfaces: PodShellSurfaces())
    defer { actions.shutdown() }
    let successful = AuthSettings(searchDirectories: ["/working"])
    var draft = store.settingsDraft
    draft.searchDirectories = "/working"
    actions.setSettingsDraft(draft)
    let first = Task { await actions.saveAuthSettings() }
    try await watchEventually { await persistence.calls == 1 }
    draft.searchDirectories = "/failing"
    actions.setSettingsDraft(draft)
    let second = Task { await actions.saveAuthSettings() }
    try await watchEventually { actions.settingsRevision == 2 }
    await persistence.gate.open()
    await first.value
    await second.value
    #expect(await persistence.load() == successful)
    #expect(try await resolver.settings() == successful)
    #expect(store.authSettings == successful && store.settingsDraft == draft)
    #expect(store.settingsDiagnostic != nil && store.settingsDiagnostic?.contains("saved") == false)
    let acquired = try await provider.acquire(for: context)
    #expect(acquired.identity.belongs(to: context, settings: successful))
    draft.searchDirectories = "/new-draft"
    actions.setSettingsDraft(draft)
    #expect(try draft.applying(to: store.authSettings, context: context).searchDirectories == ["/new-draft"])
    await actions.shutdownAndWait()
}

private actor GatedSettingsStore: AuthSettingsStoring {
    let gate = TestGate()
    private var settings = AuthSettings()
    private(set) var calls = 0
    func load() -> AuthSettings { settings }
    func save(_ value: AuthSettings) async throws {
        calls += 1
        if calls == 1 { try await gate.wait() }
        if calls == 2 { throw AuthenticationError.invalidSettings }
        settings = value
    }
}
