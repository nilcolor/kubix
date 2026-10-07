import Foundation
import KubixCore

public struct DeploymentDetailsService: DeploymentDetailsProviding {
    public typealias TransportFactory = @Sendable (ResolvedContext) async throws -> any Transport
    private let transports: TransportFactory

    public init(transports: @escaping TransportFactory) { self.transports = transports }

    public func details(
        context: ResolvedContext, namespace: String, name: String, uid: String
    ) async throws -> DeploymentDetails {
        guard NamespaceSelection.isValid(namespace), !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.utf8.contains(0), !uid.isEmpty else { throw APIError.invalidRequest }
        try Task.checkCancellation()
        let transport = try await transports(context)
        try Task.checkCancellation()
        let request = APIRequest(
            resource: ResourceKind.deployments.resource, namespace: namespace, name: name,
            apiPath: ResourceKind.deployments.apiPath
        )
        let bytes = try await transport.data(for: request)
        try Task.checkCancellation()
        let details: DeploymentDetails
        do { details = try JSONDecoder().decode(DeploymentDetails.self, from: bytes) } catch {
            throw (error as? DeploymentDetailsError) ?? .malformed
        }
        guard details.uid == uid else { throw DeploymentDetailsError.replaced }
        guard details.name == name, details.namespace == namespace else { throw DeploymentDetailsError.identityMismatch }
        guard !details.containers.isEmpty else { throw DeploymentDetailsError.noContainers }
        return details
    }
}
