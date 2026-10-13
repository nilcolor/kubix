import Foundation
import KubixCore

public struct PodDeleteService: PodDeleting {
    public typealias TransportFactory = @Sendable (ResolvedContext) async throws -> any Transport
    private let transports: TransportFactory

    public init(transports: @escaping TransportFactory) { self.transports = transports }

    public func delete(context: ResolvedContext, namespace: String, name: String, uid: String) async throws {
        guard NamespaceSelection.isValid(namespace), !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.utf8.contains(0), !uid.isEmpty else { throw APIError.invalidRequest }
        try Task.checkCancellation()
        let transport = try await transports(context)
        try Task.checkCancellation()
        let options = try JSONEncoder().encode(DeleteOptions(preconditions: .init(uid: uid)))
        // Default grace period: the kubelet stops the containers the way it would for a rollout.
        _ = try await transport.data(for: APIRequest(
            resource: "pods", namespace: namespace, name: name, method: "DELETE", body: options
        ))
    }

    private struct DeleteOptions: Encodable {
        struct Preconditions: Encodable { let uid: String }
        let apiVersion = "v1"
        let kind = "DeleteOptions"
        let preconditions: Preconditions
    }
}
