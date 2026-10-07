import Foundation

public extension AppActions {
    /// Capture the clicked row when its menu opens, not whichever row is selected later.
    func deploymentLogsMenuAction(uid: String) -> @MainActor () -> Void {
        selectRow(uid: uid)
        let generation = podLogSelectionGeneration
        let row = store.rows.first { $0.id == uid }
        return { [weak self] in
            guard let self, self.podLogSelectionGeneration == generation,
                  self.store.rows.first(where: { $0.id == uid }) == row, row != nil else { return }
            self.openDeploymentLogs(uid: uid)
        }
    }

    /// Follows every pod of the selected deployment in one tab. Two reads stand between the click and
    /// the first line: the deployment itself, for the containers its template declares and the
    /// selector that identifies its pods, and then that selector's pods.
    func openDeploymentLogs(uid: String? = nil, container: String? = nil) {
        guard !stopped, store.listKind == .deployments else { return }
        if let uid { selectRow(uid: uid) }
        cancelPendingLogs()
        guard !store.isLoadingConfiguration, logs != nil, let details = deploymentDetails, deploymentPods != nil,
              let context = store.selectedContext,
              let row = store.rows.first(where: { $0.id == store.listTable.selectedUID }),
              let name = row.metadata.name, row.metadata.namespace == store.selectedNamespace else {
            store.podLogDiagnostic = "Select an available deployment after configuration loads to open logs."
            return
        }
        let selection = RowSelection(
            id: UUID(), purpose: .logs, generation: podLogSelectionGeneration, listGeneration: listGeneration,
            configurationRevision: configurationRevision, context: context, namespace: store.selectedNamespace, row: row
        )
        podLogSelection = selection
        store.isLoadingPodDetails = true
        store.pendingContainerPurpose = .logs
        podDetailTasks[selection.id] = Task { [weak self] in
            defer { self?.podDetailTasks.removeValue(forKey: selection.id) }
            do {
                let deployment = try await details.details(
                    context: context, namespace: selection.namespace, name: name, uid: row.id
                )
                try Task.checkCancellation()
                guard let self, self.isCurrentPodSelection(selection) else { return }
                try Self.validate(deployment, name: name, namespace: selection.namespace, uid: row.id)
                let choices = deployment.containers
                guard let fallback = Self.defaultContainer(deployment) else { throw DeploymentDetailsError.noContainers }
                self.store.isLoadingPodDetails = false
                self.store.pendingContainerPurpose = nil
                if let container, let preferred = choices.first(where: { $0.name == container }) {
                    self.resolve(selection, deployment: deployment, container: preferred)
                    return
                }
                guard choices.count > 1 else {
                    self.resolve(selection, deployment: deployment, container: fallback)
                    return
                }
                self.deploymentChoices[selection.id] = deployment
                self.store.containerPicker = ContainerPickerPresentation(
                    id: selection.id, purpose: .logs, pod: "deploy/" + deployment.name,
                    containers: choices, defaultContainer: fallback.name, annotated: deployment.defaultContainer
                )
            } catch {
                guard let self, self.isCurrentPodSelection(selection) else { return }
                self.store.isLoadingPodDetails = false
                self.store.pendingContainerPurpose = nil
                self.store.podLogDiagnostic = Self.deploymentDiagnostic(error)
            }
        }
    }

    func confirmDeploymentLogs(selectionID: UUID, container: String) {
        guard let selection = podLogSelection, selection.id == selectionID,
              isCurrentPodSelection(selection), let picker = store.containerPicker,
              picker.id == selectionID, picker.purpose == .logs,
              let deployment = deploymentChoices[selectionID],
              let target = deployment.containers.first(where: { $0.name == container }) else { return }
        store.containerPicker = nil
        resolve(selection, deployment: deployment, container: target)
    }
}

extension AppActions {
    /// Kubernetes log endpoints are name-addressed and take no UID precondition, so the identity
    /// that answered is what proves the object is still the one that was clicked. The service checks
    /// this too; checking it here as well makes the guarantee the action's rather than one
    /// provider's.
    static func validate(_ deployment: DeploymentDetails, name: String, namespace: String, uid: String) throws {
        guard deployment.uid == uid else { throw DeploymentDetailsError.replaced }
        guard deployment.name == name, deployment.namespace == namespace else {
            throw DeploymentDetailsError.identityMismatch
        }
    }

    /// What the template nominates, if it is one of the containers it declares, and otherwise the
    /// first regular one — the same rule a pod's menu follows.
    static func defaultContainer(_ deployment: DeploymentDetails) -> PodDetails.Container? {
        deployment.containers.first { $0.kind == .regular && $0.name == deployment.defaultContainer }
            ?? deployment.containers.first { $0.kind == .regular }
            ?? deployment.containers.first
    }

    /// The pods are resolved after the container is chosen, so a menu left open does not hold a
    /// list that has since changed.
    func resolve(_ selection: RowSelection, deployment: DeploymentDetails, container: PodDetails.Container) {
        guard isCurrentPodSelection(selection), let listing = deploymentPods else { return }
        store.containerPicker = nil
        deploymentChoices.removeValue(forKey: selection.id)
        let scope = LogScope(
            context: selection.context, namespace: selection.namespace,
            subject: .deployment(name: deployment.name, uid: deployment.uid), container: container
        )
        let session = install(LogSession(scope: scope, containers: deployment.containers, sources: []))
        podLogGuards[session.id] = selection
        let attempt = UUID()
        deploymentLogAttempts[session.id] = attempt
        logTasks[attempt] = Task { [weak self] in
            defer { self?.logTasks.removeValue(forKey: attempt) }
            do {
                let selector = try LabelSelector(deployment.selector)
                let pods = try await listing.pods(
                    context: scope.context, namespace: scope.namespace, selector: selector
                )
                try Task.checkCancellation()
                guard let self, self.deploymentLogAttempts[session.id] == attempt, !session.isClosed,
                      self.isCurrentPodScope(selection) else { return }
                let built = self.deploymentSources(
                    pods, context: scope.context, namespace: scope.namespace, container: container
                )
                session.install(sources: built.sources, resolved: built.resolved)
                // No pods is the tab's own state, which its empty source list already reports; there
                // is nothing to start and nothing to apologise for.
                guard !built.sources.isEmpty else {
                    self.podLogGuards.removeValue(forKey: session.id)
                    if self.podLogSelection?.id == selection.id { self.podLogSelection = nil }
                    return
                }
                self.startLog(session)
            } catch {
                guard let self, self.deploymentLogAttempts[session.id] == attempt, !session.isClosed,
                      !Task.isCancelled else { return }
                self.podLogGuards.removeValue(forKey: session.id)
                self.store.podLogDiagnostic = Self.deploymentDiagnostic(error)
                self.closeLog(session.id)
            }
        }
    }

    /// A deployment's own refusals carry their own sentences — a set-based selector or a template
    /// with no containers is not a log-stream failure and must not be described as one.
    static func deploymentDiagnostic(_ error: any Error) -> String {
        if let error = error as? DeploymentDetailsError { return error.errorDescription ?? "" }
        if let error = error as? LabelSelectorFailure { return error.diagnostic }
        return deploymentLogFailure(error).diagnostic
    }
}
