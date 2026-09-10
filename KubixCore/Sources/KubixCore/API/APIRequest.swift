import Foundation

/// No credentials belong here. Only the transport adds Authorization, after URL construction.
public struct APIRequest: Sendable, CustomStringConvertible {
    public static let tableAccept = "application/json;as=Table;g=meta.k8s.io;v=v1"
    public let path: [String]
    public let query: [URLQueryItem]
    public let accept: String
    public let resourceContext: String
    public let managesCredentialRefresh: Bool
    public var description: String { "Kubernetes request: \(resourceContext)" }

    public init(
        resource: String, namespace: String? = nil, name: String? = nil,
        subresource: String? = nil, apiPath: [String] = ["api", "v1"],
        query: [URLQueryItem] = [], table: Bool = false, managesCredentialRefresh: Bool = false
    ) {
        path = apiPath + (namespace.map { ["namespaces", $0] } ?? [])
            + [resource] + (name.map { [$0] } ?? []) + (subresource.map { [$0] } ?? [])
        self.query = query
        self.managesCredentialRefresh = managesCredentialRefresh
        accept = table ? Self.tableAccept : "application/json"
        resourceContext = resource + (subresource.map { "/" + $0 } ?? "")
            + (namespace.map { " in namespace " + $0 } ?? "")
    }

    public func urlRequest(baseURL: URL, purpose: TransportPurpose = .request) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw APIError.invalidRequest
        }
        var prefix = components.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        components.percentEncodedPath = prefix + "/" + path.map(Self.encode).joined(separator: "/")
        var items = query
        if let lease = TransportPolicy.policy(for: purpose).serverLease {
            items.removeAll { $0.name == "timeoutSeconds" }
            items.append(URLQueryItem(name: "timeoutSeconds", value: String(lease)))
        }
        components.percentEncodedQuery = items.isEmpty ? nil : items.map {
            Self.encode($0.name) + ($0.value.map { "=" + Self.encode($0) } ?? "")
        }.joined(separator: "&")
        if purpose == .webSocket { components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws" }
        guard let url = components.url else { throw APIError.invalidRequest }
        var request = URLRequest(url: url)
        request.timeoutInterval = TransportPolicy.policy(for: purpose).idleTimeout
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    private static func encode(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126: String(UnicodeScalar(byte))
            default: String(format: "%%%02X", byte)
            }
        }.joined()
    }
}
