import Foundation

public extension AppActions {
    func selectContext(named name: String) throws {
        guard let context = store.contexts.first(where: { $0.name == name }) else {
            throw KubeconfigError.unknownContext
        }
        guard !stopped else { return }
        if store.selectedContext == context {
            refreshPluginPresentation()
            if store.connection == .idle { refreshPods() }
            return
        }
        store.selectedContext = context
        resetNamespaceSelection()
        store.podName = ""
        store.containerName = ""
        resetSettingsDraft()
        refreshPluginPresentation()
        refreshPods()
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
        store.namespaces = namespaceSelection.suggestions(for: store.selectedContext)
        guard store.selectedNamespace != namespace else {
            if store.connection == .idle { refreshPods() }
            return
        }
        store.selectedNamespace = namespace
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
    }

    @discardableResult
    func commitNamespaceInput() -> Bool {
        do { try selectNamespace(store.namespaceDraft); return true } catch { return false }
    }

    func reloadSelectedPods() {
        let previousGeneration = podGeneration
        guard commitNamespaceInput() else { return }
        if podGeneration == previousGeneration { refreshPods() }
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
        store.selectedPodUID = uid
        reconcilePodSelection()
    }
}

extension AppActions {
    func retryPodsAfterAuthentication(for identity: CredentialIdentity) {
        guard !stopped, let context = store.selectedContext, (try? CredentialIdentity(from: context)) == identity,
              case .failed(let error) = store.connection,
              error == .podAuthentication || error.httpCode == 401 else { return }
        refreshPods()
    }

    private func reconcilePodSelection() {
        let selected = store.podTable.selectedUID
        if store.selectedPodUID != selected { store.selectedPodUID = selected }
    }

    func resetNamespaceSelection() {
        cancelPods()
        applyPodUpdate(PodWatchUpdate(rows: [], columns: nil, connection: .idle))
        store.selectedNamespace = NamespaceSelection.defaultNamespace(for: store.selectedContext)
        store.namespaceDraft = store.selectedNamespace
        store.namespaceDiagnostic = nil
        store.namespaces = namespaceSelection.suggestions(for: store.selectedContext)
    }

    func cancelPods() {
        podGeneration = UUID()
        guard let task = podTask else { return }
        podTask = nil
        task.cancel()
        let id = UUID()
        retiringPodTasks[id] = task
        Task { [weak self] in
            await task.value
            self?.retiringPodTasks.removeValue(forKey: id)
        }
    }

    func applyPodUpdate(_ update: PodWatchUpdate) {
        if store.rows != update.rows { store.rows = update.rows }
        if store.columns != update.columns {
            store.columns = update.columns
            store.podSort = nil
        }
        if store.connection != update.connection { store.connection = update.connection }
        reconcilePodSelection()
    }
}
