import Foundation

/// Pull-based, bounded buffering. One read at a time. cancel must promptly unblock a pending read.
/// Owners must cancel on teardown; EOF and failed reads release the underlying task too.
public protocol HTTPByteStream: Sendable {
    func read() async throws -> Data?
    func cancel()
}

public struct HTTPDataResponse: Sendable {
    public let statusCode: Int
    public let body: Data
    public init(statusCode: Int, body: Data) { self.statusCode = statusCode; self.body = body }
}

public struct HTTPStreamResponse: Sendable {
    public let statusCode: Int
    public let body: any HTTPByteStream
    public init(statusCode: Int, body: any HTTPByteStream) { self.statusCode = statusCode; self.body = body }
}

/// Implementations must propagate task cancellation to IO, including response-header waits.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> HTTPDataResponse
    func stream(for request: URLRequest) async throws -> HTTPStreamResponse
}

public protocol Transport: Sendable {
    func data(for request: APIRequest) async throws -> Data
    func stream(for request: APIRequest, purpose: TransportPurpose) async throws -> any HTTPByteStream
    func webSocket(for request: APIRequest) async throws -> any WebSocketConnection
}
