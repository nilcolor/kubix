import Foundation
import KubixCore

public struct PodDetailsService: PodDetailsProviding {
    public typealias TransportFactory = @Sendable (ResolvedContext) async throws -> any Transport
    private let transports: TransportFactory

    public init(transports: @escaping TransportFactory) { self.transports = transports }

    public func details(context: ResolvedContext, namespace: String, name: String, uid: String) async throws -> PodDetails {
        guard NamespaceSelection.isValid(namespace), !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.utf8.contains(0), !uid.isEmpty else { throw APIError.invalidRequest }
        try Task.checkCancellation()
        let transport = try await transports(context)
        try Task.checkCancellation()
        let bytes = try await transport.data(for: APIRequest(resource: "pods", namespace: namespace, name: name))
        try Task.checkCancellation()
        let details: PodDetails
        do { details = try JSONDecoder().decode(PodDetails.self, from: bytes) } catch { throw PodDetailsError.malformed }
        guard details.uid == uid else { throw PodDetailsError.replaced }
        guard details.name == name, details.namespace == namespace else { throw PodDetailsError.identityMismatch }
        return details
    }
}
