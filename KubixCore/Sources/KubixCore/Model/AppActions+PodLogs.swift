import Foundation

public extension AppActions {
    func podLogsMenuAction(uid: String) -> @MainActor () -> Void {
        selectPod(uid: uid)
        let generation = podSelectionGeneration
        let row = store.rows.first { $0.id == uid }
        return { [weak self] in
            guard let self, self.podSelectionGeneration == generation,
                  self.store.rows.first(where: { $0.id == uid }) == row, row != nil else { return }
            self.openPodLogs(uid: uid)
        }
    }

    func openPodLogs(uid: String? = nil) {
        guard !stopped else { return }
        if let uid { selectPod(uid: uid) }
        cancelPodShellSelection()
        guard !store.isLoadingConfiguration, logs != nil, let details = podDetails,
              let context = store.selectedContext,
              let row = store.rows.first(where: { $0.id == store.podTable.selectedUID }),
              let name = row.metadata.name, row.metadata.namespace == store.selectedNamespace else {
            store.podLogDiagnostic = "Select an available pod after configuration loads to open logs."
            return
        }
        let selection = PodShellSelection(
            id: UUID(), generation: podSelectionGeneration, podGeneration: podGeneration,
            configurationRevision: configurationRevision, context: context, namespace: store.selectedNamespace, row: row
        )
        podLogSelection = selection
        store.isLoadingPodDetails = true
        podDetailTasks[selection.id] = Task { [weak self] in
            defer { self?.podDetailTasks.removeValue(forKey: selection.id) }
            do {
                let pod = try await details.details(context: context, namespace: selection.namespace, name: name, uid: row.id)
                try Task.checkCancellation()
                guard let self, self.isCurrentPodSelection(selection) else { return }
                try Self.validateLogPod(pod, name: name, namespace: selection.namespace, uid: row.id)
                let choices = ContainerSelection(details: pod)
                guard let container = choices.defaultLog else { throw PodDetailsError.identityMismatch }
                self.store.isLoadingPodDetails = false
                let session = self.makeLogSession(context: context, pod: pod, container: container)
                self.podLogGuards[session.id] = selection
                self.startLog(session)
            } catch {
                guard let self, self.isCurrentPodSelection(selection) else { return }
                self.store.isLoadingPodDetails = false
                self.store.podLogDiagnostic = LogFailure.classify(error).diagnostic
            }
        }
    }
}

extension AppActions {
    func cancelPodLogSelection() {
        podLogSelection = nil
        store.podLogDiagnostic = nil
        for id in Array(podLogGuards.keys) { closeLog(id) }
    }

    func makeLogSession(context: ResolvedContext, pod: PodDetails, container: PodDetails.Container) -> LogSession {
        let session = LogSession(target: LogTarget(context: context, details: pod, container: container), containers: ContainerSelection(details: pod).logs)
        store.logSessions.append(session)
        store.selectedLogSessionID = session.id
        return session
    }

    static func validateLogPod(_ pod: PodDetails, name: String, namespace: String, uid: String) throws {
        guard pod.uid == uid else { throw PodDetailsError.replaced }
        guard pod.name == name, pod.namespace == namespace else { throw PodDetailsError.identityMismatch }
    }
}
