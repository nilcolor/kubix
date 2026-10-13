import Foundation

/// What the confirmation names, so the user approves this pod in this namespace on this cluster.
public struct PodDeletionPresentation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let pod: String
    public let namespace: String
    public let context: String
}

struct PodDeletionRequest: Sendable {
    let id: UUID
    let context: ResolvedContext
    let namespace: String
    let name: String
    let uid: String
    let configurationRevision: Int
}
