import Foundation
import KubixCore

public struct NamespaceListService: NamespaceListing {
    public typealias TransportFactory = @Sendable (ResolvedContext) async throws -> any Transport

    /// Namespace rows are metadata-only and few; these bounds exist so an endless or cycling cursor
    /// cannot spin forever, not as a routine path. Hitting one throws rather than truncating.
    static let pageLimit = 16
    static let byteLimit = 8 * 1_024 * 1_024

    private let transports: TransportFactory

    public init(transports: @escaping TransportFactory) { self.transports = transports }

    public func namespaces(context: ResolvedContext) async throws -> [String] {
        try Task.checkCancellation()
        let transport = try await transports(context)
        var names: [String] = []
        var cursor = ""
        var bytes = 0
        for page in 0..<Self.pageLimit {
            try Task.checkCancellation()
            let data = try await transport.data(for: Self.request(cursor: cursor))
            bytes += data.count
            guard bytes <= Self.byteLimit else { throw NamespaceListFailure.tooManyBytes }
            guard let table = try? JSONDecoder().decode(KubernetesTable.self, from: data) else {
                throw NamespaceListFailure.malformed
            }
            // A row the server could not name is unusable here, but it does not invalidate the others.
            names.append(contentsOf: table.rows.compactMap { $0.object?.metadata?.name })
            let next = table.metadata?.continuation ?? ""
            guard !next.isEmpty else { return names }
            guard next != cursor else { throw NamespaceListFailure.malformed }
            cursor = next
            if page == Self.pageLimit - 1 { throw NamespaceListFailure.tooManyPages }
        }
        throw NamespaceListFailure.tooManyPages
    }

    private static func request(cursor: String) -> APIRequest {
        var query = [
            URLQueryItem(name: "limit", value: "500"),
            URLQueryItem(name: "includeObject", value: "Metadata"),
        ]
        if !cursor.isEmpty { query.append(URLQueryItem(name: "continue", value: cursor)) }
        return APIRequest(resource: "namespaces", apiPath: ["api", "v1"], query: query, table: true)
    }
}
