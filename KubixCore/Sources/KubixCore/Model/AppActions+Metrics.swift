import Foundation

/// Pod usage for the watched namespace. The metrics API has no watch, so it is polled for as long as
/// the pod watch runs, under the same generation: a changed namespace, context or refresh retires
/// the poll with the watch, and a late answer from a retired one is discarded.
extension AppActions {
    /// How long the last numbers stay on screen while polls fail. Past that they are no longer a
    /// description of now, and a blank cell is more honest than a stale one.
    static let metricsStaleAfter: TimeInterval = 180

    func startPodMetrics(context: ResolvedContext, namespace: String, generation: UUID) {
        guard let listing = podMetricsListing,
              store.clusters.first(where: { $0.context == context })?.metrics != .unavailable else { return }
        let interval = metricsInterval
        podMetricsTask = Task { [weak self] in
            var lastSuccess: TimeInterval?
            while !Task.isCancelled {
                let outcome: Result<[PodUsage], any Error>
                do {
                    outcome = .success(try await listing.podMetrics(context: context, namespace: namespace))
                } catch {
                    outcome = .failure(error)
                }
                guard let next = self?.receivePodMetrics(
                    outcome, context: context, generation: generation, lastSuccess: &lastSuccess
                ), next else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Whether to keep polling.
    private func receivePodMetrics(
        _ outcome: Result<[PodUsage], any Error>, context: ResolvedContext, generation: UUID,
        lastSuccess: inout TimeInterval?
    ) -> Bool {
        guard !stopped, !Task.isCancelled, listGeneration == generation else { return false }
        switch outcome {
        case .success(let usage):
            lastSuccess = monotonicNow()
            setMetrics(.available, for: context)
            // Names are unique within a namespace; the first of any duplicate is kept deterministically.
            let byName = Dictionary(usage.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            if store.podMetrics != byName { store.podMetrics = byName }
            return true
        case .failure(let error):
            if error is CancellationError { return false }
            if let error = error as? APIError, error.httpCode == 404 {
                // No metrics API on this cluster: it will not appear by asking again.
                setMetrics(.unavailable, for: context)
                return false
            }
            guard Self.isWorthRetrying(error) else {
                // Denied, or credentials that need the user. Polling on would re-run the credential
                // plugin every interval; recovery is the watch's explicit Retry, which restarts this
                // poll with it. The numbers stop being refreshed, so they stop being shown.
                if store.podMetrics?.isEmpty == false { store.podMetrics = [:] }
                return false
            }
            if let last = lastSuccess, monotonicNow() - last > Self.metricsStaleAfter, store.podMetrics?.isEmpty == false {
                store.podMetrics = [:]
            }
            return true
        }
    }

    /// Only what can clear by itself: an overloaded or restarting server, a dropped connection, a
    /// body that was unreadable this time. Everything else — a 403, a 401 after its refresh, a
    /// credential plugin that failed — needs someone to act, and asking again cannot help.
    static func isWorthRetrying(_ error: any Error) -> Bool {
        if error is PodMetricsFailure { return true }
        guard let error = error as? APIError else { return false }
        if let code = error.httpCode { return code == 429 || (500..<600).contains(code) }
        // A dropped or timed-out connection; not a TLS failure, which is configuration.
        if case .transport(let failure) = error { return [.connection, .timedOut, .closed].contains(failure) }
        return false
    }

    func setMetrics(_ value: MetricsAvailability, for context: ResolvedContext) {
        guard let index = store.clusters.firstIndex(where: { $0.context == context }),
              store.clusters[index].metrics != value else { return }
        store.clusters[index].metrics = value
    }
}
