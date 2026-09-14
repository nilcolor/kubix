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

    func openPodLogs(uid: String? = nil, container: String? = nil) {
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
        store.pendingContainerPurpose = .logs
        podDetailTasks[selection.id] = Task { [weak self] in
            defer { self?.podDetailTasks.removeValue(forKey: selection.id) }
            do {
                let pod = try await details.details(context: context, namespace: selection.namespace, name: name, uid: row.id)
                try Task.checkCancellation()
                guard let self, self.isCurrentPodSelection(selection) else { return }
                try Self.validateLogPod(pod, name: name, namespace: selection.namespace, uid: row.id)
                let choices = ContainerSelection(details: pod)
                guard let fallback = choices.defaultLog else { throw PodDetailsError.identityMismatch }
                self.store.isLoadingPodDetails = false
                self.store.pendingContainerPurpose = nil
                if let container, let preferred = choices.logs.first(where: { $0.name == container }) {
                    self.dispatchPodLogs(selection, context: context, pod: pod, container: preferred)
                    return
                }
                guard choices.logs.count > 1 else {
                    self.dispatchPodLogs(selection, context: context, pod: pod, container: fallback)
                    return
                }
                self.logChoices[selection.id] = pod
                self.store.containerPicker = ContainerPickerPresentation(
                    id: selection.id, purpose: .logs, pod: pod.name,
                    containers: choices.logs, defaultContainer: fallback.name, annotated: choices.annotated
                )
            } catch {
                guard let self, self.isCurrentPodSelection(selection) else { return }
                self.store.isLoadingPodDetails = false
                self.store.pendingContainerPurpose = nil
                self.store.podLogDiagnostic = LogFailure.classify(error).diagnostic
            }
        }
    }
}

public extension AppActions {
    func confirmPodLogs(selectionID: UUID, container: String) {
        guard let selection = podLogSelection, selection.id == selectionID,
              isCurrentPodSelection(selection), let picker = store.containerPicker,
              picker.id == selectionID, picker.purpose == .logs,
              let pod = logChoices[selectionID],
              let target = ContainerSelection(details: pod).logs.first(where: { $0.name == container }),
              let context = store.selectedContext else { return }
        store.containerPicker = nil
        dispatchPodLogs(selection, context: context, pod: pod, container: target)
    }

    func cancelPodLogs(selectionID: UUID) {
        guard podLogSelection?.id == selectionID else { return }
        store.containerPicker = nil
        logChoices.removeValue(forKey: selectionID)
        podLogSelection = nil
    }
}

extension AppActions {
    func dispatchPodLogs(
        _ selection: PodShellSelection, context: ResolvedContext, pod: PodDetails, container: PodDetails.Container
    ) {
        guard isCurrentPodSelection(selection) else { return }
        store.containerPicker = nil
        logChoices.removeValue(forKey: selection.id)
        let session = makeLogSession(context: context, pod: pod, container: container)
        podLogGuards[session.id] = selection
        startLog(session)
    }

    func cancelPodLogSelection() {
        podLogSelection = nil
        logChoices = [:]
        store.podLogDiagnostic = nil
        for id in Array(podLogGuards.keys) { closeLog(id) }
    }

    func makeLogSession(context: ResolvedContext, pod: PodDetails, container: PodDetails.Container) -> LogSession {
        let session = LogSession(target: LogTarget(context: context, details: pod, container: container), containers: ContainerSelection(details: pod).logs)
        store.logSessions.append(session)
        store.sessionOrder.append(.logs(session.id))
        store.selectedSession = .logs(session.id)
        return session
    }

    static func validateLogPod(_ pod: PodDetails, name: String, namespace: String, uid: String) throws {
        guard pod.uid == uid else { throw PodDetailsError.replaced }
        guard pod.name == name, pod.namespace == namespace else { throw PodDetailsError.identityMismatch }
    }
}
