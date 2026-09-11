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
    public var id: String { context.name }

    public init(context: ResolvedContext, state: State = .disconnected) {
        self.context = context
        self.state = state
    }

    /// A context keeps its state only while its whole snapshot is unchanged: a redefined server, user
    /// or source file is a different cluster to connect to, even under the same name.
    public static func reconcile(existing: [ClusterStatus], contexts: [ResolvedContext]) -> [ClusterStatus] {
        contexts.map { context in
            let carried = existing.first { $0.context == context }
            return ClusterStatus(context: context, state: carried?.state ?? .disconnected)
        }
    }
}
