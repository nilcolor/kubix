#if DEBUG
import Foundation
import KubixCore

enum ExecLiveDiscovery {
    static let context = "synthetic-context"
    static let namespace = "synthetic-namespace"
    static let prefix = "synthetic-pod-"
    static let container = "synthetic-container"

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
