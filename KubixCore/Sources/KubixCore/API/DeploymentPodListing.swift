import Foundation

/// One pod a deployment owns, as a log stream needs it: a name to address, a UID to bind to, and a
/// creation time to order by. Nothing is read from the printed cells — the Table prints STATUS, but a
/// printed cell is display text, not a container's state.
public struct DeploymentPod: Identifiable, Equatable, Sendable {
    public let name: String
    public let uid: String
    public let created: Date?
    public var id: String { uid }

    public init(name: String, uid: String, created: Date?) {
        self.name = name
        self.uid = uid
        self.created = created
    }
}

/// The pods matching a deployment's selector, newest first.
public protocol DeploymentPodListing: Sendable {
    func pods(context: ResolvedContext, namespace: String, selector: LabelSelector) async throws -> [DeploymentPod]
}

public enum DeploymentPodFailure: String, Error, Equatable, Sendable {
    case malformed
    /// A truncated set is not the deployment's pods: a tab that silently tailed the first page would
    /// claim to follow a workload while missing most of it.
    case tooManyPages
    case tooManyBytes
}
