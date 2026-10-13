import Foundation

public extension AppActions {
    /// Focus only. Discovery now belongs to an explicit list selection on a connected cluster, so
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
            if store.connection == .idle, browsingKind != nil { refreshList() }
            return
        }
        pauseLogsForScopeChange()
        store.selectedNamespace = namespace
        guard let kind = browsingKind else {
            // Visible rows must never describe a namespace other than the committed one.
            cancelList()
            clearList(store.listKind)
            return
        }
        refreshList(kind)
    }

    /// Lists and watches whichever kind the sidebar has selected. Without a list selection there is
    /// nothing to refresh, so the Refresh button and a namespace commit both go through here.
    func refreshList(_ requested: ResourceKind? = nil) {
        let kind = requested ?? browsingKind ?? store.listKind
        cancelList()
        clearList(kind)
        guard !stopped, let context = store.selectedContext, let lists else { return }
        guard NamespaceSelection.isValid(store.selectedNamespace) else {
            applyListUpdate(ResourceListUpdate(kind: kind, rows: [], columns: nil, connection: .failed(.invalidRequest)))
            return
        }
        let generation = listGeneration
        let namespace = store.selectedNamespace
        store.connection = .connecting
        listTask = Task { [weak self] in
            await lists.run(kind: kind, context: context, namespace: namespace) { [weak self] update in
                guard let self, !self.stopped, self.listGeneration == generation,
                      update.kind == self.store.listKind, !Task.isCancelled else { return }
                self.applyListUpdate(update)
            }
        }
        // Only a kind with usage columns has numbers to poll for.
        guard kind.supportsUsageColumns else { return }
        startPodMetrics(context: context, namespace: namespace, generation: generation)
    }

    /// Empties the slot and records which kind now owns it, so nothing can render one kind's rows
    /// under another's columns between a selection change and its first update.
    func clearList(_ kind: ResourceKind) {
        store.listKind = kind
        applyListUpdate(ResourceListUpdate(kind: kind, rows: [], columns: nil, connection: .idle))
    }

    @discardableResult
    func commitNamespaceInput() -> Bool {
        do { try selectNamespace(store.namespaceDraft); return true } catch { return false }
    }

    func setListFilter(_ value: String) {
        store.listFilter = value
        reconcileRowSelection()
    }

    func setListWide(_ value: Bool) {
        store.listWide = value
        store.listSort = store.listTable.sort
        reconcileRowSelection()
    }

    func sortList(_ value: ResourceTablePresentation.Sort?) {
        store.listSort = value
        store.listSort = store.listTable.sort
        reconcileRowSelection()
    }

    func selectRow(uid: String?) {
        if store.selectedRowUID != uid { cancelPodShellSelection() }
        store.selectedRowUID = uid
        reconcileRowSelection()
    }
}

extension AppActions {
    func retryPodsAfterAuthentication(for identity: CredentialIdentity, generation: UUID) {
        guard !stopped, listGeneration == generation, let context = store.selectedContext,
              identity.belongs(to: context, settings: store.authSettings),
              case .failed(let error) = store.connection,
              error == .podAuthentication || error == .watch(.credentialRefreshLimit) || error.httpCode == 401 else { return }
        refreshList()
    }

    private func reconcileRowSelection() {
        let selected = store.listTable.selectedUID
        if store.selectedRowUID != selected { store.selectedRowUID = selected }
        reconcilePodShellSelection()
    }

    func resetNamespaceSelection() {
        cancelList()
        clearList(store.listKind)
        store.selectedNamespace = NamespaceSelection.defaultNamespace(for: store.selectedContext)
        store.namespaceDraft = store.selectedNamespace
        store.namespaceDiagnostic = nil
        refreshNamespaceOptions()
    }

    func cancelList() {
        cancelPodShellSelection()
        cancelPendingDeletion()
        listGeneration = UUID()
        if store.podMetrics != nil { store.podMetrics = nil }
        // The metrics poll belongs to the same scope as the watch and retires with it.
        for task in [listTask, podMetricsTask].compactMap({ $0 }) {
            task.cancel()
            let id = UUID()
            retiringListTasks[id] = task
            Task { [weak self] in
                await task.value
                self?.retiringListTasks.removeValue(forKey: id)
            }
        }
        listTask = nil
        podMetricsTask = nil
    }

    func applyListUpdate(_ update: ResourceListUpdate) {
        if let uid = store.selectedRowUID,
           store.rows.first(where: { $0.id == uid }) != update.rows.first(where: { $0.id == uid }) {
            cancelPodShellSelection()
        }
        if store.rows != update.rows { store.rows = update.rows }
        if store.columns != update.columns {
            store.columns = update.columns
            store.listSort = nil
        }
        if store.connection != update.connection { store.connection = update.connection }
        reconcileLogPods(update)
        reconcileRowSelection()
    }
}
