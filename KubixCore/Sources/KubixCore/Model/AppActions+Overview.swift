import Foundation

/// The dashboard's cluster-wide counts. Nothing here is watched: eleven cluster-wide watches would
/// stream every pod change in the cluster to keep a handful of slow-moving numbers current, so the
/// counts are polled instead, and only while a connected cluster's own pane is what the user sees.
extension AppActions {
    /// How long a section's last numbers stay on screen while polls for it fail.
    static let overviewStaleAfter: TimeInterval = 180

    /// The one decision about whether the poll runs, called after anything that changes the selection
    /// or a cluster's connection. Landing on the pane starts it, so its first tick is the refresh on
    /// select; staying on it leaves a running poll alone.
    func syncOverviewPoll() {
        let target = overviewTarget
        if target == overviewContext, overviewTask != nil { return }
        retireOverviewTask()
        overviewContext = target
        guard let target, let listing = overviewListing else { return }
        let generation = UUID()
        overviewGeneration = generation
        let interval = overviewInterval
        overviewTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let sections = self?.beginOverviewTick(target, generation: generation) else { return }
                let results = await Self.fetchOverview(sections, context: target, listing: listing)
                guard self?.receiveOverview(results, context: target, generation: generation) == true else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Connect asks for everything again, permissions included, and a disconnected cluster's numbers
    /// describe a connection that no longer exists.
    func resetOverview(of name: String) {
        overviewRefreshedAt.removeValue(forKey: name)
        guard let index = store.clusters.firstIndex(where: { $0.id == name }),
              store.clusters[index].overview != ClusterOverview() else { return }
        store.clusters[index].overview = ClusterOverview()
    }

    func retireOverviewTask() {
        overviewGeneration = UUID()
        guard let task = overviewTask else { return }
        overviewTask = nil
        task.cancel()
        let id = UUID()
        retiringOverviewTasks[id] = task
        Task { [weak self] in
            await task.value
            self?.retiringOverviewTasks.removeValue(forKey: id)
        }
    }

    /// Shutdown only cancels: `shutdownAndWait` snapshots these tasks before calling it.
    func cancelOverviewWork() {
        overviewGeneration = UUID()
        overviewTask?.cancel()
        for task in retiringOverviewTasks.values { task.cancel() }
    }

    private var overviewTarget: ResolvedContext? {
        guard !stopped, overviewListing != nil, case .cluster(let name) = store.sidebarSelection,
              let cluster = store.clusters.first(where: { $0.id == name }), cluster.state == .connected else { return nil }
        return cluster.context
    }

    /// The sections still worth asking for, or nil when the poll should end.
    private func beginOverviewTick(_ context: ResolvedContext, generation: UUID) -> [OverviewSection]? {
        guard !stopped, overviewGeneration == generation,
              let cluster = store.clusters.first(where: { $0.context == context }),
              cluster.state == .connected else { return nil }
        // The Namespaces tile is the existing list, under its own 30-second throttle.
        refreshNamespaces(contextNamed: context.name)
        let sections = OverviewSection.all.filter { !cluster.overview.isSettled($0) }
        if sections.isEmpty { endOverviewPoll(generation) }
        return sections.isEmpty ? nil : sections
    }

    private nonisolated static func fetchOverview(
        _ sections: [OverviewSection], context: ResolvedContext, listing: any ClusterOverviewListing
    ) async -> [OverviewSection: Result<OverviewPayload, any Error>] {
        await withTaskGroup(of: (OverviewSection, Result<OverviewPayload, any Error>).self) { group in
            for section in sections {
                group.addTask {
                    do {
                        switch section {
                        case .nodes: return (section, .success(.nodes(try await listing.nodes(context: context))))
                        case .warningEvents: return (section, .success(.events(try await listing.warningEvents(context: context))))
                        case .workload(let kind):
                            return (section, .success(.workload(kind, try await listing.workloads(kind, context: context))))
                        }
                    } catch {
                        return (section, .failure(error))
                    }
                }
            }
            var results: [OverviewSection: Result<OverviewPayload, any Error>] = [:]
            for await (section, result) in group { results[section] = result }
            return results
        }
    }

    /// Whether to keep polling. Each section stands alone: one kind the user may not list does not
    /// blank the others.
    private func receiveOverview(
        _ results: [OverviewSection: Result<OverviewPayload, any Error>], context: ResolvedContext, generation: UUID
    ) -> Bool {
        guard !stopped, !Task.isCancelled, overviewGeneration == generation,
              let index = store.clusters.firstIndex(where: { $0.context == context }),
              store.clusters[index].state == .connected else { return false }
        let name = context.name
        let now = monotonicNow()
        var overview = store.clusters[index].overview
        var keepPolling = true
        for section in OverviewSection.all {
            guard let result = results[section] else { continue }
            switch result {
            case .success(let payload):
                payload.apply(to: &overview)
                overviewRefreshedAt[name, default: [:]][section] = now
            case .failure(let error):
                if error is CancellationError { return false }
                let fresh = overviewRefreshedAt[name]?[section].map { now - $0 <= Self.overviewStaleAfter } ?? false
                let (state, retryable) = Self.overviewFailure(error, fresh: fresh)
                if let state { overview.mark(section, state) }
                if !retryable { keepPolling = false }
            }
        }
        if store.clusters[index].overview != overview { store.clusters[index].overview = overview }
        if !keepPolling { endOverviewPoll(generation) }
        return keepPolling
    }

    /// What a failed section shows, if it changes, and whether asking again on a timer can help.
    private static func overviewFailure(_ error: any Error, fresh: Bool) -> (OverviewState?, retryable: Bool) {
        if (error as? APIError)?.httpCode == 403 { return (.notPermitted, true) }
        // Too big to count within the budget now, and it will not be smaller in thirty seconds.
        if let failure = error as? ClusterOverviewFailure, failure != .malformed { return (.tooLarge, true) }
        // A credential that needs the user must not be retried on a timer: every tick would re-run the
        // plugin. Selecting the pane again is the explicit retry.
        guard isWorthRetrying(error) || error is ClusterOverviewFailure else { return (.failed, false) }
        return (fresh ? nil : .failed, true)
    }

    /// A poll that stopped itself is forgotten, so selecting the pane again starts a fresh one.
    private func endOverviewPoll(_ generation: UUID) {
        guard overviewGeneration == generation else { return }
        overviewTask = nil
    }
}

enum OverviewPayload: Sendable {
    case nodes(NodeCounts)
    case events(Int)
    case workload(WorkloadKind, WorkloadCounts)

    func apply(to overview: inout ClusterOverview) {
        switch self {
        case .nodes(let counts): overview.nodes = .value(counts)
        case .events(let count): overview.warningEvents = .value(count)
        case .workload(let kind, let counts): overview.workloads[kind] = .value(counts)
        }
    }
}
