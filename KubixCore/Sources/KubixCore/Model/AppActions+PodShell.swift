import Foundation

public extension AppActions {
    /// Capture the clicked row when its menu opens, not whichever row is selected later.
    func podShellMenuAction(uid: String) -> @MainActor () -> Void {
        selectPod(uid: uid)
        let generation = podSelectionGeneration
        let row = store.rows.first { $0.id == uid }
        return { [weak self] in
            guard let self, self.podSelectionGeneration == generation,
                  self.store.rows.first(where: { $0.id == uid }) == row, row != nil else { return }
            self.openPodShell(uid: uid)
        }
    }

    /// Both Return and the native menu use this seam; a menu passes its clicked row explicitly.
    func openPodShell(uid: String? = nil) {
        guard !stopped else { return }
        guard !store.isLoadingConfiguration else {
            store.podShellDiagnostic = "Wait for configuration reload before opening a shell."
            return
        }
        if let uid { selectPod(uid: uid) }
        cancelPodShellSelection()
        guard let details = podDetails, let context = store.selectedContext,
              let row = store.rows.first(where: { $0.id == store.selectedPodUID }),
              store.podTable.selectedUID == row.id, let name = row.metadata.name,
              row.metadata.namespace == store.selectedNamespace else {
            store.podShellDiagnostic = "Select an available pod row to open a shell."
            return
        }
        let selection = PodShellSelection(
            id: UUID(), generation: podSelectionGeneration, podGeneration: podGeneration,
            configurationRevision: configurationRevision, context: context, namespace: store.selectedNamespace, row: row
        )
        podShellSelection = selection
        store.isLoadingPodDetails = true
        podDetailTasks[selection.id] = Task { [weak self] in
            defer { self?.podDetailTasks.removeValue(forKey: selection.id) }
            do {
                let pod = try await details.details(context: context, namespace: selection.namespace, name: name, uid: row.id)
                try Task.checkCancellation()
                guard let self, self.isCurrentPodSelection(selection) else { return }
                guard pod.uid == row.id else { throw PodDetailsError.replaced }
                guard pod.name == name, pod.namespace == selection.namespace else { throw PodDetailsError.identityMismatch }
                self.presentContainers(ContainerSelection(details: pod), selection: selection)
            } catch {
                guard let self, self.isCurrentPodSelection(selection) else { return }
                self.store.isLoadingPodDetails = false
                self.store.podShellDiagnostic = Self.podDetailsDiagnostic(error)
            }
        }
    }

    func confirmPodShell(selectionID: UUID, container: String) {
        guard let selection = podShellSelection, selection.id == selectionID,
              isCurrentPodSelection(selection), let picker = store.containerPicker,
              picker.id == selectionID, picker.containers.contains(container) else { return }
        dispatchPodShell(selection, container: container)
    }

    func cancelPodShell(selectionID: UUID) {
        guard podShellSelection?.id == selectionID else { return }
        cancelPodShellSelection()
    }
}

extension AppActions {
    func isCurrentPodSelection(_ selection: PodShellSelection) -> Bool {
        !stopped && !store.isLoadingConfiguration && selection.generation == podSelectionGeneration && selection.podGeneration == podGeneration
            && selection.configurationRevision == configurationRevision && store.selectedContext == selection.context
            && store.selectedNamespace == selection.namespace && store.podTable.selectedUID == selection.row.id
            && store.rows.first(where: { $0.id == selection.row.id }) == selection.row
    }

    func cancelPodShellSelection() {
        cancelPodLogSelection()
        podSelectionGeneration = UUID()
        podShellSelection = nil
        store.containerPicker = nil
        store.isLoadingPodDetails = false
        store.podShellDiagnostic = nil
        for task in podDetailTasks.values { task.cancel() }
        // Running sessions have already relinquished their selection guard and remain immutable.
        for id in Array(podShellGuards.keys) { closeShell(id) }
    }

    func reconcilePodShellSelection() {
        if let selection = podShellSelection, !isCurrentPodSelection(selection) { cancelPodShellSelection() }
        if let selection = podLogSelection, !isCurrentPodSelection(selection) { cancelPodShellSelection() }
    }

    func validatePodShell(_ id: UUID) throws {
        if let selection = podShellGuards[id], !isCurrentPodSelection(selection) { throw CancellationError() }
    }

    private func presentContainers(_ choices: ContainerSelection, selection: PodShellSelection) {
        store.isLoadingPodDetails = false
        guard let candidate = choices.defaultShell else {
            store.podShellDiagnostic = choices.unavailableExplanation
            return
        }
        if choices.shell.count == 1 { dispatchPodShell(selection, container: candidate) } else {
            store.containerPicker = ContainerPickerPresentation(
                id: selection.id, pod: selection.row.metadata.name ?? "", containers: choices.shell.map(\.name), defaultContainer: candidate
            )
        }
    }

    private func dispatchPodShell(_ selection: PodShellSelection, container: String) {
        guard isCurrentPodSelection(selection), let name = selection.row.metadata.name else { return }
        do {
            let target = try ExecTarget(context: selection.context, namespace: selection.namespace, pod: name, container: container)
            store.containerPicker = nil
            // openShell only schedules authentication; install the guard in the same MainActor turn.
            let id = openShell(target: target)
            podShellGuards[id] = selection
        } catch { store.podShellDiagnostic = "The selected pod cannot be used as a shell target." }
    }

    private static func podDetailsDiagnostic(_ error: any Error) -> String {
        if let error = error as? PodDetailsError { return error.localizedDescription }
        if let error = error as? APIError {
            if error.httpCode == 403 { return "Forbidden: getting this Pod requires get-pods permission. " + error.description }
            if error.httpCode == 404 { return "This pod was deleted or is no longer available. Refresh pods. " + error.description }
            return error.description
        }
        return authDiagnostic(error)
    }
}
