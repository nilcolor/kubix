import Foundation

public extension AppActions {
    /// Focus only. Discovery now belongs to an explicit `Pods` selection on a connected cluster, so
    /// choosing a context can no longer trigger credentials, a browser prompt, or a watch.
    func selectContext(named name: String) throws {
        guard let context = store.contexts.first(where: { $0.name == name }) else {
            throw KubeconfigError.unknownContext
        }
        guard !stopped else { return }
        focus(context)
    }

    func selectNamespace(_ namespace: String) throws {
        guard NamespaceSelection.isValid(namespace) else {
            store.namespaceDiagnostic = "Enter a DNS namespace: 1–63 lowercase letters, digits or hyphens, with alphanumeric ends."
            throw APIError.invalidRequest
        }
        guard !stopped else { return }
        if let context = store.selectedContext { try namespaceSelection.remember(namespace, for: context) }
        store.namespaceDraft = namespace
        store.namespaceDiagnostic = nil
        refreshNamespaceOptions()
        guard store.selectedNamespace != namespace else {
            if store.connection == .idle, isBrowsingPods { refreshPods() }
            return
        }
        pauseLogsForScopeChange()
        store.selectedNamespace = namespace
        guard isBrowsingPods else {
            // Visible rows must never describe a namespace other than the committed one.
            cancelPods()
            applyPodUpdate(PodWatchUpdate(rows: [], columns: nil, connection: .idle))
            return
        }
        refreshPods()
    }

    func refreshPods() {
        cancelPods()
        applyPodUpdate(PodWatchUpdate(rows: [], columns: nil, connection: .idle))
        guard !stopped, let context = store.selectedContext, let pods else { return }
        guard NamespaceSelection.isValid(store.selectedNamespace) else {
            applyPodUpdate(PodWatchUpdate(rows: [], columns: nil, connection: .failed(.invalidRequest)))
            return
        }
        let generation = podGeneration
        let namespace = store.selectedNamespace
        store.connection = .connecting
        podTask = Task { [weak self] in
            await pods.run(context: context, namespace: namespace) { [weak self] update in
                guard let self, !self.stopped, self.podGeneration == generation, !Task.isCancelled else { return }
                self.applyPodUpdate(update)
            }
        }
        startPodMetrics(context: context, namespace: namespace, generation: generation)
    }

    @discardableResult
    func commitNamespaceInput() -> Bool {
        do { try selectNamespace(store.namespaceDraft); return true } catch { return false }
    }

    func setPodFilter(_ value: String) {
        store.podFilter = value
        reconcilePodSelection()
    }

    func setPodWide(_ value: Bool) {
        store.podWide = value
        store.podSort = store.podTable.sort
        reconcilePodSelection()
    }

    func sortPods(_ value: PodTablePresentation.Sort?) {
        store.podSort = value
        store.podSort = store.podTable.sort
        reconcilePodSelection()
    }

    func selectPod(uid: String?) {
        if store.selectedPodUID != uid { cancelPodShellSelection() }
        store.selectedPodUID = uid
        reconcilePodSelection()
    }
}

extension AppActions {
    func retryPodsAfterAuthentication(for identity: CredentialIdentity, generation: UUID) {
        guard !stopped, podGeneration == generation, let context = store.selectedContext,
              identity.belongs(to: context, settings: store.authSettings),
              case .failed(let error) = store.connection,
              error == .podAuthentication || error == .watch(.credentialRefreshLimit) || error.httpCode == 401 else { return }
        refreshPods()
    }

    private func reconcilePodSelection() {
        let selected = store.podTable.selectedUID
        if store.selectedPodUID != selected { store.selectedPodUID = selected }
        reconcilePodShellSelection()
    }

    func resetNamespaceSelection() {
        cancelPods()
        applyPodUpdate(PodWatchUpdate(rows: [], columns: nil, connection: .idle))
        store.selectedNamespace = NamespaceSelection.defaultNamespace(for: store.selectedContext)
        store.namespaceDraft = store.selectedNamespace
        store.namespaceDiagnostic = nil
        refreshNamespaceOptions()
    }

    func cancelPods() {
        cancelPodShellSelection()
        podGeneration = UUID()
        if store.podMetrics != nil { store.podMetrics = nil }
        // The metrics poll belongs to the same scope as the watch and retires with it.
        for task in [podTask, podMetricsTask].compactMap({ $0 }) {
            task.cancel()
            let id = UUID()
            retiringPodTasks[id] = task
            Task { [weak self] in
                await task.value
                self?.retiringPodTasks.removeValue(forKey: id)
            }
        }
        podTask = nil
        podMetricsTask = nil
    }

    func applyPodUpdate(_ update: PodWatchUpdate) {
        if let uid = store.selectedPodUID,
           store.rows.first(where: { $0.id == uid }) != update.rows.first(where: { $0.id == uid }) {
            cancelPodShellSelection()
        }
        if store.rows != update.rows { store.rows = update.rows }
        if store.columns != update.columns {
            store.columns = update.columns
            store.podSort = nil
        }
        if store.connection != update.connection { store.connection = update.connection }
        reconcileLogPods(update)
        reconcilePodSelection()
    }
}
