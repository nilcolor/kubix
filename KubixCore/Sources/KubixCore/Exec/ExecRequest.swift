import Foundation

/// Pure request construction; credentials and v5 protocol negotiation belong to Transport.
public struct ExecRequest: Sendable, CustomStringConvertible {
    public let apiRequest: APIRequest
    public let tty: Bool
    public let stderr: Bool
    public var description: String { apiRequest.description }

    public init(
        namespace: String, pod: String, container: String, command: [String],
        stdin: Bool = true, stdout: Bool = true, tty: Bool = true, stderr: Bool? = nil
    ) throws {
        let stderr = stderr ?? !tty
        guard !(tty && stderr), stdin || stdout || stderr,
              [namespace, pod, container].allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              command.first?.isEmpty == false,
              ([namespace, pod, container] + command).allSatisfy({ !$0.utf8.contains(0) }) else {
            throw APIError.invalidRequest
        }
        self.tty = tty
        self.stderr = stderr
        apiRequest = APIRequest(resource: "pods", namespace: namespace, name: pod, subresource: "exec", query:
            command.map { URLQueryItem(name: "command", value: $0) } + [
                URLQueryItem(name: "container", value: container),
                URLQueryItem(name: "stdin", value: String(stdin)),
                URLQueryItem(name: "stdout", value: String(stdout)),
                URLQueryItem(name: "stderr", value: String(stderr)),
                URLQueryItem(name: "tty", value: String(tty)),
            ]
        )
    }

    public func urlRequest(baseURL: URL) throws -> URLRequest {
        try apiRequest.urlRequest(baseURL: baseURL, purpose: .webSocket)
    }
}
