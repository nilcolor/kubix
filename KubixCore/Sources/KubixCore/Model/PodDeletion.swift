import Foundation

/// What the confirmation names, so the user approves these pods in this namespace on this cluster.
public struct PodDeletionPresentation: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// In the order the table showed them.
    public let pods: [String]
    public let namespace: String
    public let context: String
}

struct PodDeletionRequest: Sendable {
    struct Target: Sendable {
        let name: String
        let uid: String
    }

    let id: UUID
    let context: ResolvedContext
    let namespace: String
    let targets: [Target]
    let configurationRevision: Int
}
