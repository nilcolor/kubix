import Foundation
import KubixCore

public struct ClusterProbeService: ClusterProbing {
    public typealias TransportFactory = @Sendable (ResolvedContext) async throws -> any Transport
    private let transports: TransportFactory

    public init(transports: @escaping TransportFactory) { self.transports = transports }

    /// `/version` is outside every namespace, so success means credentials were accepted and the
    /// apiserver answered — never that any namespaced resource is authorized. It also needs no RBAC
    /// beyond the default public-info role, so connecting cannot fail for lack of a permission the
    /// user was never going to grant.
    public func probe(context: ResolvedContext) async throws -> String? {
        try Task.checkCancellation()
        let transport = try await transports(context)
        try Task.checkCancellation()
        let data = try await transport.data(for: APIRequest(resource: "version", apiPath: []))
        // Only the version string is kept: an unreadable body still means the apiserver answered.
        return (try? JSONDecoder().decode(ServerVersion.self, from: data))?.gitVersion
    }

    private struct ServerVersion: Decodable { let gitVersion: String? }
}
