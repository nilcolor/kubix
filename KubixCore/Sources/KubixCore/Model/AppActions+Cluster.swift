import Foundation

public extension AppActions {
    /// Connecting is one unnamespaced probe. Credentials are acquired by the transport serving it, so a
    /// plugin can still request browser approval, and success says nothing about namespaced access.
    func connect(contextNamed name: String) {
        guard !stopped, let probe, let index = store.clusters.firstIndex(where: { $0.id == name }) else { return }
        let context = store.clusters[index].context
        retireClusterTask(name)
        let generation = UUID()
        clusterGenerations[name] = generation
        store.clusters[index].state = .connecting
        clusterTasks[name] = Task { [weak self] in
            do {
                try await probe.probe(context: context)
                self?.finishConnect(context, generation: generation, failure: nil)
            } catch {
                self?.finishConnect(context, generation: generation, failure: error)
            }
        }
    }

    /// Disconnecting abandons the cluster's own watch, never its sessions: a running shell keeps the
    /// context, namespace, pod and container it was opened against.
    func disconnect(contextNamed name: String) {
        guard !stopped, let index = store.clusters.firstIndex(where: { $0.id == name }) else { return }
        retireClusterTask(name)
        clusterGenerations[name] = UUID()
        store.clusters[index].state = .disconnected
        demotePodsSelection(of: name)
        discardNamespaces(of: name)
        guard store.selectedContext?.name == name else { return }
        cancelPods()
        applyPodUpdate(PodWatchUpdate(rows: [], columns: nil, connection: .idle))
    }
}

public extension AppActions {
    /// The only route into discovery: `Pods` under a connected cluster. A cluster row is focus alone,
    /// and one watch at a time follows the selection rather than accumulating per cluster.
    func selectSidebar(_ selection: SidebarSelection) {
        guard !stopped, let cluster = store.clusters.first(where: { $0.id == selection.clusterName }) else { return }
        if case .pods = selection, cluster.state != .connected { return }
        let unchanged = store.sidebarSelection == selection
        store.sidebarSelection = selection
        focus(cluster.context)
        guard case .pods = selection else { return }
        guard !unchanged || store.connection == .idle else { return }
        refreshPods()
    }
}

extension AppActions {
    var isBrowsingPods: Bool {
        guard case .pods(let name) = store.sidebarSelection else { return false }
        return store.clusters.first { $0.id == name }?.state == .connected
    }

    /// Everything `selectContext` used to do apart from starting discovery.
    func focus(_ context: ResolvedContext) {
        guard store.selectedContext != context else {
            refreshPluginPresentation()
            return
        }
        pauseLogsForScopeChange()
        store.selectedContext = context
        resetNamespaceSelection()
        resetSettingsDraft()
        refreshPluginPresentation()
    }

    /// The probe is only an answer about the snapshot it ran against: a kubeconfig reload can redefine
    /// a context under the same name, and a result from the old definition must not describe the new
    /// one. The generation alone cannot catch that, because it is keyed by the name that survived.
    func finishConnect(_ context: ResolvedContext, generation: UUID, failure: (any Error)?) {
        let name = context.name
        guard !stopped, clusterGenerations[name] == generation,
              let index = store.clusters.firstIndex(where: { $0.id == name }),
              store.clusters[index].context == context else { return }
        clusterTasks.removeValue(forKey: name)
        store.clusters[index].state = failure.map { .failed(reason: Self.connectReason($0)) } ?? .connected
        if failure != nil {
            demotePodsSelection(of: name)
            discardNamespaces(of: name)
            return
        }
        listNamespaces(context, resetting: true)
    }

    /// A reload that drops or redefines a cluster leaves its connect work pointless: the result can no
    /// longer be written, so the request and its transport are held for nothing.
    func retireClusterWork(notMatching contexts: [ResolvedContext]) {
        for name in clusterTasks.keys where !contexts.contains(where: { $0.name == name }) {
            retireClusterTask(name)
        }
        for context in contexts where !store.clusters.contains(where: { $0.context == context }) {
            retireClusterTask(context.name)
            retireNamespaceTask(context.name)
        }
        for name in namespaceFetches.keys where !contexts.contains(where: { $0.name == name }) {
            retireNamespaceTask(name)
        }
    }

    /// A `Pods` selection cannot outlive its cluster's connection: it would keep showing a table for a
    /// cluster the app is no longer talking to.
    func demotePodsSelection(of name: String) {
        guard case .pods(let selected) = store.sidebarSelection, selected == name else { return }
        store.sidebarSelection = .cluster(name)
    }

    /// Connect failures are not one error type, and an HTTP or TLS failure is not an authentication
    /// problem — describing it as one would send the user to the plugin for a network fault.
    static func connectReason(_ error: any Error) -> String {
        if let error = error as? APIError { return error.description }
        if let error = error as? KubeconfigError { return error.description }
        return authDiagnostic(error)
    }

    func retireClusterTask(_ name: String) {
        guard let task = clusterTasks.removeValue(forKey: name) else { return }
        task.cancel()
        let id = UUID()
        retiringClusterTasks[id] = task
        Task { [weak self] in
            await task.value
            self?.retiringClusterTasks.removeValue(forKey: id)
        }
    }

    /// Shutdown only cancels: `shutdownAndWait` snapshots these tasks before calling it, so the join
    /// still has something to await.
    func cancelClusterWork() {
        for name in clusterTasks.keys { clusterGenerations[name] = UUID() }
        for task in clusterTasks.values { task.cancel() }
        for task in retiringClusterTasks.values { task.cancel() }
    }
}
