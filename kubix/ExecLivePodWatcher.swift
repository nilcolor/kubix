#if DEBUG
import Foundation
import KubixCore
import KubixRuntime

/// Legacy read-only exec validation can publish only one explicitly authorized metadata Table row.
/// Before discovery selects that target, context/namespace activation performs no request.
actor ExecLivePodWatcher: ResourceWatching {
    private let transports: @Sendable (ResolvedContext) async throws -> any Transport
    private var target: ExecTarget?
    private let integrated: Bool
    private var armed = false

    init(transports: @escaping @Sendable (ResolvedContext) async throws -> any Transport, integrated: Bool = false) {
        self.transports = transports
        self.integrated = integrated
    }

    func armAcceptance() { armed = true }

    func select(_ target: ExecTarget) throws {
        guard target.context.name == ExecLiveDiscovery.context, target.namespace == ExecLiveDiscovery.namespace,
              target.pod.hasPrefix(ExecLiveDiscovery.prefix), target.container == ExecLiveDiscovery.container else {
            throw APIError.invalidRequest
        }
        self.target = target
    }

    func run(
        kind: ResourceKind, context: ResolvedContext, namespace: String,
        update: @escaping @MainActor @Sendable (ResourceListUpdate) -> Void
    ) async {
        if integrated {
            guard armed, context.name == ExecLiveDiscovery.context, namespace == ExecLiveDiscovery.namespace else { return }
            await WatchService(transports: transports).run(kind: .pods, context: context, namespace: namespace, update: update)
            return
        }
        guard let target, context == target.context, namespace == target.namespace else { return }
        do {
            let transport = try await transports(context)
            try Task.checkCancellation()
            let data = try await transport.data(for: APIRequest(resource: "pods", namespace: namespace, query: [
                .init(name: "fieldSelector", value: "metadata.name=\(target.pod)"), .init(name: "includeObject", value: "Metadata"),
                .init(name: "limit", value: "1"),
            ], table: true))
            try Task.checkCancellation()
            let table = try JSONDecoder().decode(KubernetesTable.self, from: data)
            let rows = try table.rows.map { try ResourceRow(row: $0) }
            guard rows.count == 1, rows[0].metadata.name == target.pod, rows[0].metadata.namespace == namespace,
                  table.metadata?.continuation?.isEmpty != false else { throw APIError.invalidRequest }
            await update(.init(kind: .pods, rows: rows, columns: table.columnDefinitions, connection: .live))
        } catch {
            guard !Task.isCancelled else { return }
            await update(.init(kind: .pods, rows: [], columns: nil, connection: .failed((error as? APIError) ?? .invalidRequest)))
        }
    }
}
#endif
