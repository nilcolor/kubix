import Foundation

public extension AppActions {
    func loadConfiguration() async {
        guard !stopped, let configurations else { return }
        cancelPodShellSelection()
        pauseLogsForScopeChange()
        configurationRevision += 1
        let revision = configurationRevision
        let settingsVersion = settingsRevision
        let committedSettingsVersion = committedSettingsRevision
        store.isLoadingConfiguration = true
        let snapshot = await configurations.load()
        guard !stopped, revision == configurationRevision else { return }
        store.contexts = snapshot.contexts
        store.configurationDiagnostics = snapshot.diagnostics
        let selectedName = store.selectedContext?.name ?? snapshot.preferredContext
        store.selectedContext = snapshot.contexts.first(where: { $0.name == selectedName }) ?? snapshot.contexts.first
        resetNamespaceSelection()
        if settingsVersion == settingsRevision, committedSettingsVersion == committedSettingsRevision,
           let settings = snapshot.settings { store.authSettings = settings }
        store.isLoadingConfiguration = false
        store.hasLoadedConfiguration = true
        resetSettingsDraft()
        refreshPluginPresentation()
    }

    func setNamespaceInput(_ value: String) { store.namespaceDraft = value; store.namespaceDiagnostic = nil }
    func setShowingSettings(_ value: Bool) {
        store.showingSettings = value
        if value { resetSettingsDraft() }
    }
    func setUseDeviceCode(_ value: Bool) { store.useDeviceCode = value }
    func setSettingsDraft(_ value: AuthSettingsDraft) { settingsDraftRevision += 1; store.settingsDraft = value }

    func selectShell(_ id: UUID) {
        guard store.execSessions.contains(where: { $0.id == id && !$0.isClosed }) else { return }
        store.selectedExecSessionID = id
        store.selectedLogSessionID = nil
    }

    func saveAuthSettings() async {
        let draftRevision = settingsDraftRevision
        settingsSaveRevision += 1
        let revision = settingsSaveRevision
        do {
            let settings = try store.settingsDraft.applying(to: store.authSettings, context: store.selectedContext)
            try await updateAuthSettings(settings)
            if !stopped, revision == settingsSaveRevision, draftRevision == settingsDraftRevision {
                store.settingsDiagnostic = "Settings saved. Existing sessions retain their original targets."
            }
        } catch {
            if !stopped, revision == settingsSaveRevision, draftRevision == settingsDraftRevision {
                store.settingsDiagnostic = Self.authDiagnostic(error)
            }
        }
    }

    func signInSelectedContext() async {
        guard let context = store.selectedContext else { return }
        try? await signIn(context: context, useDeviceCode: store.useDeviceCode)
    }

    func authenticateSelectedContext() async {
        guard let context = store.selectedContext else { return }
        try? await acquireCredentials(context: context)
    }

    @discardableResult
    func openAuthorizationURL(operationID: UUID) async -> Bool {
        guard !stopped, let session = store.authenticationSessions[operationID],
              let url = AuthPresentation(session).authorizationURL else { return false }
        let opened = await browser?.open(url) ?? false
        guard !stopped, store.authenticationSessions[operationID]?.state.isTerminal == false else { return opened }
        store.authenticationDiagnostic = opened ? nil : "The browser could not be opened. Follow the live HTTPS instructions or retry with device-code sign-in."
        return opened
    }
}

extension AppActions {
    func resetSettingsDraft(afterCommit: Bool = false) {
        if !afterCommit { settingsDraftRevision += 1 }
        store.settingsDraft = AuthSettingsDraft(settings: store.authSettings, context: store.selectedContext)
        store.settingsDiagnostic = nil
    }

    func refreshPluginPresentation() {
        presentationTask?.cancel()
        presentationRevision += 1
        let revision = presentationRevision
        store.pluginPresentation = AuthPluginPresentation()
        guard let context = store.selectedContext else { return }
        presentationTask = Task { [weak self, authentication] in
            let presentation = await authentication.presentation(for: context)
            guard let self, !self.stopped, self.presentationRevision == revision else { return }
            self.store.pluginPresentation = presentation
        }
    }
}
