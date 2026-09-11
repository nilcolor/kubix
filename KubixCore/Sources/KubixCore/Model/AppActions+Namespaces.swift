import Foundation

public extension AppActions {
    /// Refreshes the focused cluster's namespaces. Called when the picker is about to open, so the list
    /// is current when it is looked at rather than polled.
    func refreshNamespaces() {
        guard let name = store.sidebarSelection?.clusterName else { return }
        refreshNamespaces(contextNamed: name)
    }

    /// Listing is an enhancement, so every reason to skip it is silent: a cluster that is not connected
    /// makes no request at all, a cluster that refused once is never asked again on its own, and a
    /// recent success is reused rather than re-fetched.
    func refreshNamespaces(contextNamed name: String) {
        guard !stopped, let cluster = store.clusters.first(where: { $0.id == name }),
              cluster.state == .connected, cluster.namespaces != .unavailable else { return }
        let fetch = namespaceFetches[name]
        guard fetch?.task == nil else { return }
        if let succeededAt = fetch?.succeededAt, monotonicNow() - succeededAt < Self.namespaceRefreshInterval {
            return
        }
        listNamespaces(cluster.context)
    }
}

extension AppActions {
    static let namespaceRefreshInterval: TimeInterval = 30

    /// A deliberate Connect asks for the whole handshake again, permissions included, so it clears a
    /// previous refusal rather than inheriting it.
    func listNamespaces(_ context: ResolvedContext, resetting: Bool = false) {
        guard !stopped, namespaceListing != nil,
              let index = store.clusters.firstIndex(where: { $0.context == context }) else { return }
        if resetting, store.clusters[index].namespaces != .unknown {
            store.clusters[index].namespaces = .unknown
        }
        let name = context.name
        retireNamespaceTask(name)
        let generation = UUID()
        let previous = namespaceFetches[name]?.succeededAt
        namespaceFetches[name] = NamespaceFetch(
            generation: generation, context: context, task: nil, succeededAt: resetting ? nil : previous
        )
        namespaceFetches[name]?.task = Task { [weak self, listing = namespaceListing] in
            do {
                let names = try await listing?.namespaces(context: context) ?? []
                self?.finishNamespaces(context, generation: generation, result: .listed(names))
            } catch {
                self?.finishNamespaces(context, generation: generation, result: .unavailable)
            }
        }
    }

    func finishNamespaces(_ context: ResolvedContext, generation: UUID, result: NamespaceDiscovery) {
        let name = context.name
        guard !stopped, namespaceFetches[name]?.generation == generation,
              let index = store.clusters.firstIndex(where: { $0.id == name }),
              // The list describes the snapshot it was requested for, not whatever now holds the name.
              store.clusters[index].context == context, store.clusters[index].state == .connected else {
            return
        }
        namespaceFetches[name]?.task = nil
        if case .listed = result { namespaceFetches[name]?.succeededAt = monotonicNow() }
        store.clusters[index].namespaces = result
        refreshNamespaceOptions()
    }

    /// The picker shows one cluster's namespaces — the focused one — so a background cluster finishing
    /// its list must not replace what is on screen.
    func refreshNamespaceOptions() {
        let discovery = store.selectedContext.flatMap { context in
            store.clusters.first { $0.context == context }?.namespaces
        } ?? .unknown
        let options = namespaceSelection.options(for: store.selectedContext, discovery: discovery)
        if store.namespaces != options { store.namespaces = options }
    }

    func discardNamespaces(of name: String) {
        retireNamespaceTask(name)
        namespaceFetches.removeValue(forKey: name)
        guard let index = store.clusters.firstIndex(where: { $0.id == name }),
              store.clusters[index].namespaces != .unknown else { return }
        store.clusters[index].namespaces = .unknown
        // The visible options describe a connection that no longer exists until this recomputes them.
        refreshNamespaceOptions()
    }

    func retireNamespaceTask(_ name: String) {
        guard let task = namespaceFetches[name]?.task else { return }
        namespaceFetches[name]?.task = nil
        task.cancel()
        let id = UUID()
        retiringNamespaceTasks[id] = task
        Task { [weak self] in
            await task.value
            self?.retiringNamespaceTasks.removeValue(forKey: id)
        }
    }

    /// Shutdown only cancels: `shutdownAndWait` snapshots these tasks before calling it.
    func cancelNamespaceWork() {
        for name in namespaceFetches.keys { namespaceFetches[name]?.generation = UUID() }
        for fetch in namespaceFetches.values { fetch.task?.cancel() }
        for task in retiringNamespaceTasks.values { task.cancel() }
    }
}
