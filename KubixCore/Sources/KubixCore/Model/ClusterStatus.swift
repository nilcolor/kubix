import Foundation

/// Connection state per kubeconfig context. "Connected" means credentials were accepted and the
/// apiserver answered, not that any namespaced resource is authorized or being watched.
public struct ClusterStatus: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        /// Rendered text, because the failures reaching here are not one type: credential acquisition,
        /// unsupported kubeconfig shapes and transport errors all arrive without a common error type.
        case failed(reason: String)
    }

    public let context: ResolvedContext
    public var state: State
    public var namespaces: NamespaceDiscovery
    /// What the apiserver called itself at Connect. Display only, and absent for a server that
    /// answered without a readable version.
    public var serverVersion: String?
    /// Whether this connection serves pod usage. Per cluster rather than per namespace, so the usage
    /// columns stay put while the namespace changes instead of vanishing until the next sample.
    public var metrics: MetricsAvailability
    public var id: String { context.name }

    public init(
        context: ResolvedContext, state: State = .disconnected, namespaces: NamespaceDiscovery = .unknown,
        serverVersion: String? = nil, metrics: MetricsAvailability = .unknown
    ) {
        self.context = context
        self.state = state
        self.namespaces = namespaces
        self.serverVersion = serverVersion
        self.metrics = metrics
    }

    /// A context keeps its state only while its whole snapshot is unchanged: a redefined server, user
    /// or source file is a different cluster to connect to, even under the same name.
    public static func reconcile(existing: [ClusterStatus], contexts: [ResolvedContext]) -> [ClusterStatus] {
        contexts.map { context in
            let carried = existing.first { $0.context == context }
            return ClusterStatus(
                context: context, state: carried?.state ?? .disconnected,
                namespaces: carried?.namespaces ?? .unknown, serverVersion: carried?.serverVersion,
                metrics: carried?.metrics ?? .unknown
            )
        }
    }
}

/// What is known about a cluster's namespaces. `unknown` and `unavailable` are deliberately distinct:
/// without that, a cluster that refused the list request could not be told from one never asked, and
/// would be asked again every time the picker opened.
public enum NamespaceDiscovery: Equatable, Sendable {
    case unknown
    case listed([String])
    case unavailable
}
