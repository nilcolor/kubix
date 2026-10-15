import Foundation

public extension AppActions {
    typealias PodDeleteMenuAction = (pods: Int, perform: @MainActor () -> Void)

    var offersPodDeletion: Bool { podDeleter != nil && store.listKind.supportsDelete }

    /// nil when there is nothing to offer, so the menu leaves the item out rather than disabling it.
    /// A row that is part of a multiple selection acts for the whole selection, as Finder does;
    /// any other row acts alone.
    func podDeleteMenuAction(uid: String) -> PodDeleteMenuAction? {
        guard offersPodDeletion else { return nil }
        let selected = store.listTable.selectedUIDs
        let uids = selected.count > 1 && selected.contains(uid) ? selected : [uid]
        return (uids.count, { [weak self] in self?.requestPodDeletion(uids: uids) })
    }

    /// Asks for confirmation only; nothing is sent until `confirmPodDeletion`.
    func requestPodDeletion(uids: [String]) {
        guard !stopped, offersPodDeletion, !store.isLoadingConfiguration,
              let context = store.selectedContext else { return }
        let namespace = store.selectedNamespace
        let targets = uids.compactMap { uid -> PodDeletionRequest.Target? in
            guard let row = store.rows.first(where: { $0.id == uid }), let name = row.metadata.name,
                  row.metadata.namespace == namespace else { return nil }
            return .init(name: name, uid: uid)
        }
        guard !targets.isEmpty else { return }
        selectRows(uids: Set(targets.map(\.uid)))
        let request = PodDeletionRequest(
            id: UUID(), context: context, namespace: namespace, targets: targets,
            configurationRevision: configurationRevision
        )
        podDeletionRequest = request
        store.podDeleteDiagnostic = nil
        store.podDeletion = PodDeletionPresentation(
            id: request.id, pods: targets.map(\.name), namespace: namespace, context: context.name
        )
    }

    func confirmPodDeletion(id: UUID) {
        guard let request = podDeletionRequest, request.id == id else { return }
        cancelPodDeletion(id: id)
        guard !stopped, let podDeleter else { return }
        guard !store.isLoadingConfiguration, request.configurationRevision == configurationRevision,
              store.selectedContext == request.context, store.selectedNamespace == request.namespace,
              store.listKind.supportsDelete else {
            store.podDeleteDiagnostic = "Nothing was deleted: the cluster or namespace changed before "
                + "\(Self.subject(request.targets)) was confirmed."
            return
        }
        podDeleteTasks[id] = Task { [weak self] in
            defer { self?.podDeleteTasks.removeValue(forKey: id) }
            var failures: [String] = []
            // One at a time: cancelling at quit then stops every delete not yet sent, and a large
            // selection does not arrive at the apiserver as a burst. Each carries its own UID
            // precondition, so one refusal does not stop the rest.
            for target in request.targets {
                do {
                    try await podDeleter.delete(
                        context: request.context, namespace: request.namespace, name: target.name, uid: target.uid
                    )
                } catch {
                    guard let self, !self.stopped, !Task.isCancelled, !(error is CancellationError) else { return }
                    // An auth failure reads the same for every pod and is worth saying once.
                    let message = Self.podDeleteDiagnostic(error, pod: target.name)
                    if !failures.contains(message) { failures.append(message) }
                    self.store.podDeleteDiagnostic = failures.joined(separator: "\n")
                }
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

    private static func subject(_ targets: [PodDeletionRequest.Target]) -> String {
        targets.count == 1 ? targets[0].name : "the deletion of \(targets.count) pods"
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
