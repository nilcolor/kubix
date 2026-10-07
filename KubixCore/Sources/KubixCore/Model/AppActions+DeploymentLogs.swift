import Foundation

extension AppActions {
    /// A deployment's streams, newest pod first and bounded. Returning the found count separately is
    /// what lets the tab say "the 50 newest of 180" instead of quietly tailing a subset.
    func deploymentSources(
        _ pods: [DeploymentPod], context: ResolvedContext, namespace: String, container: PodDetails.Container
    ) -> (sources: [LogSource], resolved: Int?) {
        let kept = pods.prefix(LogSession.maximumSources)
        let sources = kept.compactMap { pod -> LogSource? in
            guard let target = try? LogTarget(
                context: context, namespace: namespace, pod: pod.name, uid: pod.uid, container: container
            ) else { return nil }
            return LogSource(target: target)
        }
        return (sources, pods.count > sources.count ? pods.count : nil)
    }

    /// Resume re-reads the deployment and re-resolves its pods, so a tab that went quiet through a
    /// rollout picks up the replicas that exist now. The UID must still match: this tab follows one
    /// deployment and never adopts a different one created under the same name.
    func revalidateDeployment(_ session: LogSession, container: String?) {
        guard let details = deploymentDetails, let pods = deploymentPods else { return }
        let scope = session.scope
        let attempt = UUID()
        let revision = configurationRevision
        deploymentLogAttempts[session.id] = attempt
        session.isPaused = false
        session.sources = session.sources.map { LogSource(id: $0.id, target: $0.target, state: .connecting) }
        logTasks[attempt] = Task { [weak self] in
            defer { self?.logTasks.removeValue(forKey: attempt) }
            do {
                let deployment = try await details.details(
                    context: scope.context, namespace: scope.namespace,
                    name: scope.subject.name, uid: scope.subject.uid
                )
                try Task.checkCancellation()
                guard let self, self.deploymentLogAttempts[session.id] == attempt, !session.isClosed,
                      revision == self.configurationRevision else { return }
                let name = container ?? scope.container.name
                guard let chosen = deployment.containers.first(where: { $0.name == name }) else {
                    throw DeploymentDetailsError.identityMismatch
                }
                let found = try await pods.pods(
                    context: scope.context, namespace: scope.namespace,
                    selector: try LabelSelector(deployment.selector)
                )
                try Task.checkCancellation()
                guard self.deploymentLogAttempts[session.id] == attempt, !session.isClosed,
                      revision == self.configurationRevision else { return }
                self.restart(
                    session, deployment: deployment, pods: found,
                    container: chosen, switched: container != nil
                )
            } catch {
                guard let self, self.deploymentLogAttempts[session.id] == attempt, !session.isClosed else { return }
                self.failDeployment(session, error: error)
            }
        }
    }

    private func restart(
        _ session: LogSession, deployment: DeploymentDetails, pods: [DeploymentPod],
        container: PodDetails.Container, switched: Bool
    ) {
        let scope = session.scope
        let built = deploymentSources(pods, context: scope.context, namespace: scope.namespace, container: container)
        guard !switched else {
            // A container switch is a new tab, as it is for a pod: the old lines stay where they
            // were logged, under the container that logged them.
            session.isPaused = true
            startLog(install(LogSession(
                scope: LogScope(
                    context: scope.context, namespace: scope.namespace,
                    subject: .deployment(name: deployment.name, uid: deployment.uid), container: container
                ),
                containers: deployment.containers, sources: built.sources, resolved: built.resolved
            )))
            return
        }
        session.containers = deployment.containers
        for source in session.sources { invalidateSource(source.id) }
        session.sources = built.sources
        session.resolved = built.resolved
        // An empty set is the tab's `noPods` state, which its derived state already reports.
        guard !built.sources.isEmpty else { return }
        startLog(session)
    }

    private func failDeployment(_ session: LogSession, error: any Error) {
        guard !Task.isCancelled else {
            session.isPaused = true
            return
        }
        let failure = Self.deploymentLogFailure(error)
        guard !session.sources.isEmpty else {
            // With no source to carry a state, the tab has only its empty-set reading to offer, so
            // the reason goes where the user asked for the logs.
            store.podLogDiagnostic = failure.diagnostic
            return
        }
        for source in session.sources { session.update(source.id, state: .failed(failure)) }
    }

    static func deploymentLogFailure(_ error: any Error) -> LogFailure {
        if let error = error as? DeploymentDetailsError {
            return error == .replaced ? .replaced : .invalidTarget
        }
        if error is LabelSelectorFailure { return .invalidTarget }
        if error is DeploymentPodFailure { return .transport }
        return LogFailure.classify(error)
    }
}
