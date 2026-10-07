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

public extension DeploymentPod {
    /// Newest first, because during a rollout the new replicas are the ones worth reading, and that
    /// is also the order a capped set keeps. Pods the server dated identically, or not at all, fall
    /// back to their names so the order is stable between calls.
    ///
    /// Applied both by the listing and again where the ceiling is applied: keeping the newest must
    /// not depend on what order a provider happened to return.
    static func newestFirst(_ pods: [DeploymentPod]) -> [DeploymentPod] {
        pods.sorted { lhs, rhs in
            let left = lhs.created?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude
            let right = rhs.created?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude
            if left != right { return left > right }
            return lhs.name < rhs.name
        }
    }
}

/// The pods a deployment actually owns, newest first.
///
/// `owner` is the Deployment's UID, and it is the answer rather than the selector: a Deployment's
/// `spec.selector` is not required to be unique, so one chart's `synthetic-container` selector can match
/// `web-dj-slow`'s pods as well. Ownership runs pods → ReplicaSet → Deployment and is
/// exact; the selector only narrows what has to be fetched.
public protocol DeploymentPodListing: Sendable {
    func pods(
        context: ResolvedContext, namespace: String, owner: String, selector: LabelSelector
    ) async throws -> [DeploymentPod]
}

public enum DeploymentPodFailure: String, Error, Equatable, Sendable {
    case malformed
    /// A truncated set is not the deployment's pods: a tab that silently tailed the first page would
    /// claim to follow a workload while missing most of it.
    case tooManyPages
    case tooManyBytes
}
