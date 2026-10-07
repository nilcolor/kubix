import Foundation

public extension AppActions {
    /// Capture the clicked row when its menu opens, not whichever row is selected later.
    func podShellMenuAction(uid: String) -> @MainActor () -> Void {
        selectRow(uid: uid)
        let generation = podSelectionGeneration
        let row = store.rows.first { $0.id == uid }
        return { [weak self] in
            guard let self, self.podSelectionGeneration == generation,
                  self.store.rows.first(where: { $0.id == uid }) == row, row != nil else { return }
            self.openPodShell(uid: uid)
        }
    }

    /// Both Return and the native menu use this seam; a menu passes its clicked row explicitly.
    func openPodShell(uid: String? = nil, container: String? = nil) {
        guard !stopped else { return }
        guard !store.isLoadingConfiguration else {
            store.podShellDiagnostic = "Wait for configuration reload before opening a shell."
            return
        }
        if let uid { selectRow(uid: uid) }
        cancelPendingShell()
        guard let details = podDetails, let context = store.selectedContext,
              let row = store.rows.first(where: { $0.id == store.selectedRowUID }),
              store.listTable.selectedUID == row.id, let name = row.metadata.name,
              row.metadata.namespace == store.selectedNamespace else {
            store.podShellDiagnostic = "Select an available pod row to open a shell."
            return
        }
        let selection = RowSelection(
            id: UUID(), purpose: .shell, generation: podSelectionGeneration, listGeneration: listGeneration,
            configurationRevision: configurationRevision, context: context, namespace: store.selectedNamespace, row: row
        )
        podShellSelection = selection
        store.isLoadingPodDetails = true
        store.pendingContainerPurpose = .shell
        podDetailTasks[selection.id] = Task { [weak self] in
            defer { self?.podDetailTasks.removeValue(forKey: selection.id) }
            do {
                let pod = try await details.details(context: context, namespace: selection.namespace, name: name, uid: row.id)
                try Task.checkCancellation()
                guard let self, self.isCurrentPodSelection(selection) else { return }
                guard pod.uid == row.id else { throw PodDetailsError.replaced }
                guard pod.name == name, pod.namespace == selection.namespace else { throw PodDetailsError.identityMismatch }
                self.presentContainers(ContainerSelection(details: pod), selection: selection, preferred: container)
            } catch {
                guard let self, self.isCurrentPodSelection(selection) else { return }
                self.store.isLoadingPodDetails = false
                self.store.pendingContainerPurpose = nil
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
        cancelPendingShell()
    }
}

extension AppActions {
    /// A pending request: the scope it was made in, and the generation that says it has not been
    /// superseded by a newer request of its own kind.
    func isCurrentPodSelection(_ selection: RowSelection) -> Bool {
        let generation = selection.purpose == .shell ? podSelectionGeneration : podLogSelectionGeneration
        return selection.generation == generation && isCurrentPodScope(selection)
    }

    /// A session that has been created but is still connecting: it depends on the scope it was
    /// validated against, not on whether another session has since been asked for. Opening a second
    /// shell or log tail is not a reason to discard the first.
    func isCurrentPodScope(_ selection: RowSelection) -> Bool {
        !stopped && !store.isLoadingConfiguration && selection.listGeneration == listGeneration
            && selection.configurationRevision == configurationRevision && store.selectedContext == selection.context
            && store.selectedNamespace == selection.namespace && store.listTable.selectedUID == selection.row.id
            && store.rows.first(where: { $0.id == selection.row.id }) == selection.row
    }

    /// Everything: both pending requests and the sessions still guarded by them. This is the scope
    /// change path — a different row, namespace, context or reloaded configuration.
    func cancelPodShellSelection() {
        cancelPendingShell()
        cancelPendingLogs()
        // Running sessions have already relinquished their selection guard and remain immutable.
        for id in Array(podShellGuards.keys) { closeShell(id) }
        for id in Array(podLogGuards.keys) { closeLog(id) }
    }

    /// Only the pending shell: its own generation, its own request, its own guarded sessions. A log
    /// tail waiting for its stream to open is a separate tab the user also asked for.
    func cancelPendingShell() {
        podSelectionGeneration = UUID()
        if let pending = podShellSelection { podDetailTasks.removeValue(forKey: pending.id)?.cancel() }
        podShellSelection = nil
        shellChoices = [:]
        if store.containerPicker?.purpose == .shell { store.containerPicker = nil }
        if store.pendingContainerPurpose == .shell {
            store.isLoadingPodDetails = false
            store.pendingContainerPurpose = nil
        }
        store.podShellDiagnostic = nil
    }

    func reconcilePodShellSelection() {
        if let selection = podShellSelection, !isCurrentPodSelection(selection) { cancelPodShellSelection() }
        if let selection = podLogSelection, !isCurrentPodSelection(selection) { cancelPodShellSelection() }
    }

    func validatePodShell(_ id: UUID) throws {
        if let selection = podShellGuards[id], !isCurrentPodScope(selection) { throw CancellationError() }
    }

    private func presentContainers(
        _ choices: ContainerSelection, selection: RowSelection, preferred: String? = nil
    ) {
        store.isLoadingPodDetails = false
        store.pendingContainerPurpose = nil
        guard let candidate = choices.defaultShell else {
            store.podShellDiagnostic = choices.unavailableExplanation
            return
        }
        shellChoices[selection.id] = choices.shell
        if let preferred, choices.shell.contains(where: { $0.name == preferred }) {
            dispatchPodShell(selection, container: preferred)
        } else if choices.shell.count == 1 { dispatchPodShell(selection, container: candidate) } else {
            store.containerPicker = ContainerPickerPresentation(
                id: selection.id, purpose: .shell, pod: selection.row.metadata.name ?? "",
                containers: choices.shell, defaultContainer: candidate, annotated: choices.annotated
            )
        }
    }

    private func dispatchPodShell(_ selection: RowSelection, container: String) {
        guard isCurrentPodSelection(selection), let name = selection.row.metadata.name else { return }
        do {
            let target = try ExecTarget(context: selection.context, namespace: selection.namespace, pod: name, container: container)
            store.containerPicker = nil
            // openShell only schedules authentication; install the guard in the same MainActor turn.
            let id = openShell(target: target, containers: shellChoices[selection.id] ?? [])
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
