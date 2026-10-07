#if DEBUG
import Foundation
import KubixCore

/// Which live pod the exec driver is allowed to touch, read from the environment rather than
/// written down here. A driver that names somebody's cluster in its source is useless to everyone
/// else and publishes their infrastructure to anyone who reads the repository; the root path beside
/// these has always come from the environment, and so should the target.
///
/// All four are required. The driver refuses to run when any is missing, which is the same way
/// `KUBIX_EXEC_VALIDATION_CONFIRM` already gates it — there is no default, because a default would
/// be a guess at somebody's cluster.
enum ExecLiveDiscovery {
    static let context = value(Variable.context)
    static let namespace = value(Variable.namespace)
    static let prefix = value(Variable.prefix)
    static let container = value(Variable.container)

    private enum Variable {
        static let context = "KUBIX_EXEC_VALIDATION_CONTEXT"
        static let namespace = "KUBIX_EXEC_VALIDATION_NAMESPACE"
        static let prefix = "KUBIX_EXEC_VALIDATION_POD_PREFIX"
        static let container = "KUBIX_EXEC_VALIDATION_CONTAINER"
        static let all = [context, namespace, prefix, container]
    }

    /// Whether a real target was supplied. Asked of the environment rather than of the values above,
    /// because those fall back to synthetic names — so a missing variable would otherwise look like
    /// a configured one. Every variable must be set, or none counts: a half-configured driver would
    /// filter on a partly-synthetic target, which matches nothing it was pointed at.
    static var isConfigured: Bool {
        let environment = ProcessInfo.processInfo.environment
        return Variable.all.allSatisfy { (environment[$0] ?? "").isEmpty == false }
    }

    /// Synthetic unless the environment names a real target. `ExecLiveScopedTransport` enforces this
    /// triple on every request and is itself exercised by the synthetic native check, which needs a
    /// coherent target to exercise it with; the live driver is gated on `isConfigured` instead, so a
    /// fallback can never become something this actually talks to.
    private static func value(_ name: String) -> String {
        let configured = ProcessInfo.processInfo.environment[name] ?? ""
        guard configured.isEmpty else { return configured }
        switch name {
        case Variable.context: return "synthetic-context"
        case Variable.namespace: return "synthetic-namespace"
        case Variable.prefix: return "synthetic-pod-"
        default: return "synthetic-container"
        }
    }

    struct Metadata: Decodable {
        let name: String
        let namespace: String
        let uid: String
        let deletionTimestamp: String?
    }
    struct ContainerSpec: Decodable { let name: String }
    struct PodSpec: Decodable { let containers: [ContainerSpec] }
    struct Running: Decodable {}
    struct ContainerState: Decodable { let running: Running? }
    struct ContainerStatus: Decodable {
        let name: String
        let ready: Bool
        let state: ContainerState
    }
    struct PodStatus: Decodable {
        let phase: String?
        let containerStatuses: [ContainerStatus]?
    }
    struct Pod: Decodable {
        let metadata: Metadata
        let spec: PodSpec
        let status: PodStatus
        var allowed: Bool {
            metadata.namespace == ExecLiveDiscovery.namespace && metadata.name.hasPrefix(ExecLiveDiscovery.prefix)
                && metadata.deletionTimestamp == nil && status.phase == "Running"
                && spec.containers.filter { $0.name == ExecLiveDiscovery.container }.count == 1
                && status.containerStatuses?.contains { $0.name == ExecLiveDiscovery.container && $0.state.running != nil } == true
        }
        var ready: Bool { status.containerStatuses?.first { $0.name == ExecLiveDiscovery.container }?.ready == true }
    }
    private struct ListMetadata: Decodable {
        let continuation: String?
        enum CodingKeys: String, CodingKey { case continuation = "continue" }
    }
    private struct Page: Decodable {
        let metadata: ListMetadata
        let items: [Pod]
    }
    struct Version: Decodable { let gitVersion: String }

    static func select(using transport: any Transport) async throws -> (Pod, Int) {
        var continuation = ""
        var seen = Set<String>()
        var matches: [Pod] = []
        var pages = 0
        repeat {
            var query = [URLQueryItem(name: "limit", value: "200")]
            if !continuation.isEmpty { query.append(.init(name: "continue", value: continuation)) }
            let data = try await transport.data(for: APIRequest(resource: "pods", namespace: namespace, query: query))
            let page = try JSONDecoder().decode(Page.self, from: data)
            matches += page.items.filter(\.allowed)
            pages += 1
            continuation = page.metadata.continuation ?? ""
            if !continuation.isEmpty {
                guard seen.insert(continuation).inserted, pages < 1_000 else { throw ExecLiveValidation.Failure.pagination }
            }
        } while !continuation.isEmpty
        guard let listed = matches.sorted(by: { $0.metadata.name < $1.metadata.name }).first else {
            throw ExecLiveValidation.Failure.noMatchingPod
        }
        let bytes = try await transport.data(for: APIRequest(resource: "pods", namespace: namespace, name: listed.metadata.name))
        let selected = try JSONDecoder().decode(Pod.self, from: bytes)
        guard selected.allowed, selected.metadata.uid == listed.metadata.uid,
              selected.metadata.name == listed.metadata.name else { throw ExecLiveValidation.Failure.targetChanged }
        return (selected, pages)
    }
}
#endif
