import Foundation

/// The listed row's UID travels with the request as a server-side precondition: a pod recreated
/// under the same name since it was listed is refused by the apiserver (409) instead of deleted.
/// A fresh GET first would only narrow that race, not close it.
public protocol PodDeleting: Sendable {
    func delete(context: ResolvedContext, namespace: String, name: String, uid: String) async throws
}
