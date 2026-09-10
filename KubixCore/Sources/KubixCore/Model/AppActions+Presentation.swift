import Foundation

public extension AppActions {
    func loadConfiguration() async {
        guard !stopped, let configurations else { return }
        configurationRevision += 1
        let revision = configurationRevision
        let settingsVersion = settingsRevision
        store.isLoadingConfiguration = true
        let snapshot = await configurations.load()
        guard !stopped, revision == configurationRevision else { return }
        store.contexts = snapshot.contexts
        store.configurationDiagnostics = snapshot.diagnostics
        let selectedName = store.selectedContext?.name ?? snapshot.preferredContext
        store.selectedContext = snapshot.contexts.first(where: { $0.name == selectedName }) ?? snapshot.contexts.first
        store.selectedNamespace = store.selectedContext?.namespace ?? "default"
        store.namespaces = [store.selectedNamespace]
        store.podName = ""
        store.containerName = ""
        if settingsVersion == settingsRevision, let settings = snapshot.settings { store.authSettings = settings }
        store.isLoadingConfiguration = false
        store.hasLoadedConfiguration = true
        resetSettingsDraft()
        refreshPluginPresentation()
    }

    func setPodName(_ value: String) { store.podName = value }
    func setContainerName(_ value: String) { store.containerName = value }
    func setNamespaceInput(_ value: String) { store.selectedNamespace = value }
    func setShowingSettings(_ value: Bool) {
        store.showingSettings = value
        if value { resetSettingsDraft() }
    }
    func setUseDeviceCode(_ value: Bool) { store.useDeviceCode = value }
    func setSettingsDraft(_ value: AuthSettingsDraft) { store.settingsDraft = value }

    func selectShell(_ id: UUID) {
        guard store.execSessions.contains(where: { $0.id == id && !$0.isClosed }) else { return }
        store.selectedExecSessionID = id
    }

    @discardableResult
    func connectShell() -> UUID? {
        do {
            guard let context = store.selectedContext else { throw KubeconfigError.unknownContext }
            let target = try ExecTarget(
                context: context, namespace: store.selectedNamespace, pod: store.podName, container: store.containerName
            )
            try selectNamespace(target.namespace)
            store.connectDiagnostic = nil
            return openShell(target: target)
        } catch {
            store.connectDiagnostic = "Select a configured context and enter an explicit namespace, pod, and running regular container."
            return nil
        }
    }

    func saveAuthSettings() async {
        do {
            let settings = try store.settingsDraft.applying(to: store.authSettings, context: store.selectedContext)
            try await updateAuthSettings(settings)
            if !stopped { store.settingsDiagnostic = "Settings saved. Existing sessions retain their original targets." }
        } catch {
            if !stopped { store.settingsDiagnostic = Self.authDiagnostic(error) }
        }
    }

    func signInSelectedContext() async {
        guard let context = store.selectedContext else { return }
        try? await signIn(context: context, useDeviceCode: store.useDeviceCode)
    }

    func openAuthorizationURL(operationID: UUID) async {
        guard !stopped, let session = store.authenticationSessions[operationID],
              let url = AuthPresentation(session).authorizationURL else { return }
        let opened = await browser?.open(url) ?? false
        guard !stopped, store.authenticationSessions[operationID]?.state.isTerminal == false else { return }
        store.authenticationDiagnostic = opened ? nil : "The browser could not be opened. Follow the live HTTPS instructions or retry with device-code sign-in."
    }
}

extension AppActions {
    func resetSettingsDraft() {
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
