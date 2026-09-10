import Foundation

public struct LogRequest: Sendable {
    public let request: APIRequest
    public let purpose: TransportPurpose

    public init(
        namespace: String, pod: String, container: String, follow: Bool = true,
        tailLines: Int? = 200, timestamps: Bool = true, sinceSeconds: Int? = nil, previous: Bool = false
    ) throws {
        guard NamespaceSelection.isValid(namespace),
              [pod, container].allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.utf8.contains(0) }),
              tailLines.map({ $0 >= 0 }) ?? true, sinceSeconds.map({ $0 > 0 }) ?? true else { throw APIError.invalidRequest }
        var query = [
            URLQueryItem(name: "follow", value: String(follow)),
            URLQueryItem(name: "container", value: container),
            URLQueryItem(name: "timestamps", value: String(timestamps)),
            URLQueryItem(name: "previous", value: String(previous)),
        ]
        if let tailLines { query.append(URLQueryItem(name: "tailLines", value: String(tailLines))) }
        if let sinceSeconds { query.append(URLQueryItem(name: "sinceSeconds", value: String(sinceSeconds))) }
        request = APIRequest(resource: "pods", namespace: namespace, name: pod, subresource: "log", query: query)
        purpose = follow ? .logs : .request
    }
}
