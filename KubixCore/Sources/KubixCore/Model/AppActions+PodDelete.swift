import Foundation

public extension AppActions {
    /// nil when there is nothing to offer, so the menu leaves the item out rather than disabling it.
    func podDeleteMenuAction(uid: String) -> (@MainActor () -> Void)? {
        guard podDeleter != nil, store.listKind.supportsDelete else { return nil }
        return { [weak self] in self?.requestPodDeletion(uid: uid) }
    }

    /// Asks for confirmation only; nothing is sent until `confirmPodDeletion`.
    func requestPodDeletion(uid: String) {
        guard !stopped, podDeleter != nil, store.listKind.supportsDelete, !store.isLoadingConfiguration,
              let context = store.selectedContext, let row = store.rows.first(where: { $0.id == uid }),
              let name = row.metadata.name, row.metadata.namespace == store.selectedNamespace else { return }
        selectRow(uid: uid)
        let request = PodDeletionRequest(
            id: UUID(), context: context, namespace: store.selectedNamespace, name: name, uid: uid,
            configurationRevision: configurationRevision
        )
        podDeletionRequest = request
        store.podDeleteDiagnostic = nil
        store.podDeletion = PodDeletionPresentation(
            id: request.id, pod: name, namespace: request.namespace, context: context.name
        )
    }

    func confirmPodDeletion(id: UUID) {
        guard let request = podDeletionRequest, request.id == id else { return }
        cancelPodDeletion(id: id)
        guard !stopped, let podDeleter else { return }
        guard !store.isLoadingConfiguration, request.configurationRevision == configurationRevision,
              store.selectedContext == request.context, store.selectedNamespace == request.namespace,
              store.listKind.supportsDelete else {
            store.podDeleteDiagnostic = "Nothing was deleted: the cluster or namespace changed before \(request.name) was confirmed."
            return
        }
        podDeleteTasks[id] = Task { [weak self] in
            defer { self?.podDeleteTasks.removeValue(forKey: id) }
            do {
                try await podDeleter.delete(
                    context: request.context, namespace: request.namespace, name: request.name, uid: request.uid
                )
            } catch {
                guard let self, !self.stopped, !(error is CancellationError) else { return }
                self.store.podDeleteDiagnostic = Self.podDeleteDiagnostic(error, pod: request.name)
            }
        }
    }

    func cancelPodDeletion(id: UUID) {
        guard podDeletionRequest?.id == id else { return }
        podDeletionRequest = nil
        store.podDeletion = nil
    }

    /// The dialog went away on its own. SwiftUI may report that before running the button that
    /// closed it, so this hides it without forgetting what a Delete click still has to confirm.
    func podDeletionDialogClosed() {
        store.podDeletion = nil
    }
}

extension AppActions {
    func cancelPendingDeletion() {
        podDeletionRequest = nil
        store.podDeletion = nil
    }

    private static func podDeleteDiagnostic(_ error: any Error, pod: String) -> String {
        guard let error = error as? APIError else { return authDiagnostic(error) }
        if case .transport = error {
            return "The request to delete \(pod) did not complete, so it may or may not have been deleted. "
                + "The list shows what the server has."
        }
        switch error.httpCode {
        case 403: return "Forbidden: deleting \(pod) requires delete-pods permission. " + error.description
        case 404: return "\(pod) was already gone; nothing was deleted."
        case 409: return "\(pod) was replaced since it was listed (UID changed); nothing was deleted. Refresh pods."
        default: return "Could not delete \(pod). " + error.description
        }
    }
}
