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
        retireClusterWork(notMatching: snapshot.contexts)
        store.clusters = ClusterStatus.reconcile(existing: store.clusters, contexts: snapshot.contexts)
        let selection = SidebarSelection.reconcile(
            store.sidebarSelection, clusters: store.clusters, preferred: snapshot.preferredContext
        )
        store.sidebarSelection = selection
        store.selectedContext = selection.flatMap { current in
            store.clusters.first { $0.id == current.clusterName }?.context
        }
        resetNamespaceSelection()
        if settingsVersion == settingsRevision, committedSettingsVersion == committedSettingsRevision,
           let settings = snapshot.settings { store.authSettings = settings }
        store.isLoadingConfiguration = false
        store.hasLoadedConfiguration = true
        resetSettingsDraft()
        refreshPluginPresentation()
    }

    func setDeckFraction(_ value: Double) {
        guard !stopped, value.isFinite else { return }
        let clamped = min(AppStore.deckFractionMaximum, max(AppStore.deckFractionMinimum, value))
        if store.deckFraction != clamped { store.deckFraction = clamped }
    }

    func setNamespaceInput(_ value: String) { store.namespaceDraft = value; store.namespaceDiagnostic = nil }
    func setShowingSettings(_ value: Bool) {
        store.showingSettings = value
        if value { resetSettingsDraft() }
    }
    func setUseDeviceCode(_ value: Bool) { store.useDeviceCode = value }

    /// Dismisses the messages the pods page floats over its table. They are transient explanations of
    /// an action that failed, not a record: the next attempt replaces them anyway.
    func dismissPodDiagnostics() {
        store.podShellDiagnostic = nil
        store.podLogDiagnostic = nil
        store.podDeleteDiagnostic = nil
        store.namespaceDiagnostic = nil
    }
    func setSettingsDraft(_ value: AuthSettingsDraft) { settingsDraftRevision += 1; store.settingsDraft = value }

    func selectShell(_ id: UUID) {
        guard store.execSessions.contains(where: { $0.id == id && !$0.isClosed }) else { return }
        store.selectedSession = .shell(id)
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

extension AppActions {
    static func authDiagnostic(_ error: any Error) -> String {
        if let error = error as? AuthenticationError { return error.errorDescription ?? "Authentication failed." }
        if let error = error as? AuthError { return error.description }
        if let error = error as? any AuthenticationDiagnosticProviding { return error.authenticationDiagnostic }
        if error is CancellationError { return "Authentication was cancelled." }
        return "Authentication failed. Check the configured plugin/profile and explicitly retry."
    }
}
