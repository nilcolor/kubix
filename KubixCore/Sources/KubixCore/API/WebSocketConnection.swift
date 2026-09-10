import Foundation

/// A connection returned by a connector is upgraded, but not necessarily the requested protocol.
/// ping returns only on pong, or throws on send/pong failure. Control traffic must not share
/// an application-data lock. cancel is idempotent, nonblocking and unblocks every pending call.
public protocol WebSocketConnection: Sendable {
    var negotiatedProtocol: String? { get }
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func ping() async throws
    func cancel()
}

public protocol WebSocketConnector: Sendable {
    func connect(request: URLRequest) async throws -> any WebSocketConnection
}

/// Only a positively observed pre-upgrade HTTP response permits an authentication retry.
/// Foundation does not consistently expose a failed-upgrade response body (or even its status).
public struct WebSocketHandshakeError: Error, Sendable, CustomStringConvertible {
    public let statusCode: Int
    public let body: Data
    public init(statusCode: Int, body: Data = Data()) { self.statusCode = statusCode; self.body = body }
    public var description: String { "WebSocket HTTP upgrade failed (\(statusCode)); body redacted" }
}
