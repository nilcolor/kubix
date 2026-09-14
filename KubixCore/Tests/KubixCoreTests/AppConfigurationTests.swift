import Foundation
import KubixCore
import Testing

private actor SnapshotLoader: AppConfigurationLoading {
    var snapshot: AppConfiguration
    let gate: AppTestGate?
    init(_ snapshot: AppConfiguration, gate: AppTestGate? = nil) { self.snapshot = snapshot; self.gate = gate }
    func set(_ snapshot: AppConfiguration) { self.snapshot = snapshot }
    func load() async -> AppConfiguration {
        let captured = snapshot
        try? await gate?.wait()
        return captured
    }
}

@Test func configurationShowsBrokenEntriesAndEmptyConfigurationInsteadOfSilentSuccess() {
    let config = Kubeconfig(
        currentContext: "absent", clusters: [.init(name: "ok", cluster: .init(server: "https://synthetic.invalid"))],
        contexts: [.init(name: "bad", context: .init(cluster: "absent")), .init(name: "ok", context: .init(cluster: "ok"))]
    )
    let snapshot = AppConfiguration(configuration: config, settings: AuthSettings())
    #expect(snapshot.contexts.map(\.name) == ["ok"])
    #expect(snapshot.diagnostics.count == 2)
    #expect(snapshot.diagnostics[0].contains("bad"))
    #expect(AppConfiguration(configuration: Kubeconfig(), settings: nil).diagnostics.count == 1)
}

@Test @MainActor func configurationReloadAndPickerChangesNeverRetargetAnExistingSession() async throws {
    var snapshot = AppConfiguration(configuration: nil, settings: AuthSettings())
    snapshot.contexts = [try appContext(), try appContext("second")]
    snapshot.preferredContext = "second"
    let loader = SnapshotLoader(snapshot)
    let store = AppStore()
    let auth = AppTestAuth()
    let surfaces = AppTestSurfaces()
    let actions = AppActions(
        store: store, exec: AppTestExec(), authentication: auth, surfaces: surfaces, configurations: loader
    )
    defer { actions.shutdown() }
    await actions.loadConfiguration()
    #expect(store.selectedContext?.name == "second")
    actions.openPodShell()
    #expect(store.podShellDiagnostic != nil && surfaces.created.isEmpty)
    actions.setNamespaceInput("known")
    #expect(actions.commitNamespaceInput())
    let id = actions.openShell(target: try ExecTarget(
        context: #require(store.selectedContext), namespace: store.selectedNamespace, pod: "explicit-pod", container: "regular"
    ))
    let original = store.execSessions[0].target
    snapshot.contexts = [try appContext()]
    snapshot.diagnostics = ["A configured context is unavailable."]
    await loader.set(snapshot)
    await actions.loadConfiguration()
    #expect(store.execSessions[0].target == original)
    #expect(store.containerPicker == nil)
    #expect(store.configurationDiagnostics == snapshot.diagnostics)
    await auth.gate.open()
    try await appEventually { surfaces.created[id] != nil }
    let second = actions.openShell(target: try appTarget())
    actions.selectShell(id)
    #expect(store.selectedSession == .shell(id))
    actions.closeShell(id)
    #expect(store.selectedSession == .shell(second))
    #expect(surfaces.created[id]?.closes == 1)
}

@Test(arguments: [true, false]) @MainActor
func nativeOwnerShutdownWaitsForSessionAndAuthenticationCleanup(closeFirst: Bool) async throws {
    let auth = AppTestAuth()
    await auth.gate.open()
    let exec = AppTestExec()
    let surfaces = AppTestSurfaces()
    let store = AppStore()
    let actions = AppActions(store: store, exec: exec, authentication: auth, surfaces: surfaces)
    let id = actions.openShell(target: try appTarget())
    try await appEventually { await exec.runs[id]?.continuation != nil }
    if closeFirst { actions.closeShell(id) }
    await actions.shutdownAndWait()
    #expect(await exec.ended.contains(id))
    #expect(surfaces.created[id]?.closes == 1)
    #expect(store.authenticationSessions.isEmpty)
    #expect(actions.surface(for: id) == nil)
    await actions.shutdownAndWait()
    #expect(surfaces.created[id]?.closes == 1)
}

@Test @MainActor func delayedReloadCannotOverwriteMoreRecentSavedAuthSettings() async throws {
    let gate = AppTestGate()
    let loader = SnapshotLoader(AppConfiguration(configuration: nil, settings: AuthSettings()), gate: gate)
    let store = AppStore()
    let actions = AppActions(
        store: store, exec: AppTestExec(), authentication: AppTestAuth(), surfaces: AppTestSurfaces(), configurations: loader
    )
    defer { actions.shutdown() }
    let reload = Task { await actions.loadConfiguration() }
    try await appEventually { await gate.count == 1 }
    let updated = AuthSettings(searchDirectories: ["/new/tools"])
    try await actions.updateAuthSettings(updated)
    await gate.open()
    await reload.value
    #expect(store.authSettings == updated)
    #expect(store.settingsDraft.searchDirectories == "/new/tools")
}

@Test @MainActor func reloadStartedDuringPendingSaveCannotOverwriteItsLaterSuccessfulCommit() async throws {
    let saveGate = AppTestGate()
    let reloadGate = AppTestGate()
    let loader = SnapshotLoader(AppConfiguration(configuration: nil, settings: AuthSettings()), gate: reloadGate)
    let store = AppStore()
    let auth = AppTestAuth(settingsGate: saveGate)
    let actions = AppActions(
        store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces(), configurations: loader
    )
    defer { actions.shutdown() }
    let updated = AuthSettings(searchDirectories: ["/working"])
    let save = Task { try await actions.updateAuthSettings(updated) }
    try await appEventually { await saveGate.count == 1 }
    let reload = Task { await actions.loadConfiguration() }
    try await appEventually { await reloadGate.count == 1 }
    await saveGate.open()
    try await save.value
    await reloadGate.open()
    await reload.value
    #expect(store.authSettings == updated && store.settingsDraft.searchDirectories == "/working")
}
