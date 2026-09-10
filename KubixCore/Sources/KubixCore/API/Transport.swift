import Foundation

/// Pull-based, bounded buffering. One read at a time. cancel must promptly unblock a pending read.
/// Owners must cancel on teardown; EOF and failed reads release the underlying task too.
public protocol HTTPByteStream: Sendable {
    func read() async throws -> Data?
    func cancel()
    func credentialRejection(_ error: APIError) -> APIError
}

public extension HTTPByteStream {
    func credentialRejection(_ error: APIError) -> APIError { error }
}

public struct HTTPDataResponse: Sendable {
    public let statusCode: Int
    public let body: Data
    public let retryAfter: String?
    public init(statusCode: Int, body: Data, retryAfter: String? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.retryAfter = retryAfter
    }
}

public struct HTTPStreamResponse: Sendable {
    public let statusCode: Int
    public let body: any HTTPByteStream
    public let retryAfter: String?
    public init(statusCode: Int, body: any HTTPByteStream, retryAfter: String? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.retryAfter = retryAfter
    }
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
    func invalidateCredentials(after error: APIError) async throws
}

public extension Transport {
    /// Transports without a generation receipt cannot safely invalidate arbitrary credentials.
    func invalidateCredentials(after error: APIError) async throws {
        throw APIError.credentialsExhausted(error)
    }
}
