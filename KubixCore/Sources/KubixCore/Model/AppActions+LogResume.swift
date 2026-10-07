import Foundation

extension AppActions {
    /// Resume, and the container switch that shares its path. Either way the tab's own identity is
    /// revalidated first: a pod session rejects a replaced UID, and a deployment session rejects a
    /// replaced deployment before re-resolving which pods it owns now.
    func revalidateLog(_ id: UUID, container: String?) {
        guard !stopped, let session = logSession(id) else { return }
        pauseLog(id)
        guard !store.isLoadingConfiguration, store.selectedContext == session.scope.context,
              store.selectedNamespace == session.scope.namespace else {
            session.isPaused = false
            session.sources = session.sources.map {
                LogSource(id: $0.id, target: $0.target, state: .failed(.unavailable))
            }
            if session.sources.isEmpty { session.resolved = nil }
            return
        }
        switch session.scope.subject {
        case .pod: revalidatePod(session, container: container)
        case .deployment: revalidateDeployment(session, container: container)
        }
    }

    private func revalidatePod(_ session: LogSession, container: String?) {
        guard let details = podDetails, let source = session.sources.first else { return }
        let attempt = UUID()
        logAttempts[source.id] = attempt
        let revision = configurationRevision
        session.isPaused = false
        session.update(source.id, state: .connecting)
        logTasks[attempt] = Task { [weak self] in
            defer { self?.logTasks.removeValue(forKey: attempt) }
            let target = source.target
            do {
                let pod = try await details.details(
                    context: target.context, namespace: target.namespace, name: target.pod, uid: target.uid
                )
                try Task.checkCancellation()
                guard let self, self.logAttempts[source.id] == attempt, !session.isClosed,
                      revision == self.configurationRevision else { return }
                try Self.validateLogPod(pod, name: target.pod, namespace: target.namespace, uid: target.uid)
                let name = container ?? target.container.name
                guard let chosen = pod.containers.first(where: { $0.name == name }),
                      container != nil || chosen.kind == target.container.kind else {
                    throw PodDetailsError.identityMismatch
                }
                if container != nil {
                    // A container switch is a new tab, not a rebinding: the old lines stay where
                    // they were logged.
                    session.isPaused = true
                    self.startLog(self.makeLogSession(context: target.context, pod: pod, container: chosen))
                } else {
                    session.containers = ContainerSelection(details: pod).logs
                    self.startLog(session)
                }
            } catch {
                guard let self, self.logAttempts[source.id] == attempt, !session.isClosed else { return }
                if Task.isCancelled {
                    session.isPaused = true
                } else {
                    session.update(source.id, state: .failed(LogFailure.classify(error)))
                }
            }
        }
    }
}
