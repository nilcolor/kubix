import Foundation
import KubixCore

public protocol TransportSession: HTTPClient, WebSocketConnector {}

public protocol TransportSessionFactory: Sendable {
    func make(purpose: TransportPurpose, trust: ClusterTrustPolicy) -> any TransportSession
}

public struct URLSessionFactory: TransportSessionFactory {
    public init() {}
    public func make(purpose: TransportPurpose, trust: ClusterTrustPolicy) -> any TransportSession {
        URLSessionHTTPClient(purpose: purpose, trust: trust)
    }

    public static func configuration(for purpose: TransportPurpose) -> URLSessionConfiguration {
        let policy = TransportPolicy.policy(for: purpose)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = policy.idleTimeout
        configuration.timeoutIntervalForResource = policy.totalTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }
}

public final class URLSessionHTTPClient: TransportSession, Sendable {
    private let session: URLSession
    private let trust: ClusterTrustPolicy

    public init(purpose: TransportPurpose, trust: ClusterTrustPolicy) {
        self.trust = trust
        session = URLSession(
            configuration: URLSessionFactory.configuration(for: purpose),
            delegate: ClusterTrustDelegate(policy: trust), delegateQueue: nil
        )
    }

    public func data(for request: URLRequest) async throws -> HTTPDataResponse {
        let delegate = ClusterTrustDelegate(policy: trust)
        do {
            let (data, response) = try await session.data(for: request, delegate: delegate)
            guard let response = response as? HTTPURLResponse else { throw APIError.transport(.invalidResponse) }
            return HTTPDataResponse(statusCode: response.statusCode, body: data)
        } catch { throw delegate.authenticationFailure ?? transportError(error) }
    }

    public func stream(for request: URLRequest) async throws -> HTTPStreamResponse {
        let delegate = ClusterTrustDelegate(policy: trust)
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            guard let response = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw APIError.transport(.invalidResponse)
            }
            return HTTPStreamResponse(statusCode: response.statusCode, body: URLSessionByteStream(bytes: bytes))
        } catch { throw delegate.authenticationFailure ?? transportError(error) }
    }

    public func connect(request: URLRequest) async throws -> any WebSocketConnection {
        try await URLSessionWebSocketConnection.connect(session: session, request: request, trust: trust)
    }

    deinit { session.invalidateAndCancel() }
}

private actor URLSessionByteStream: HTTPByteStream {
    private var iterator: URLSession.AsyncBytes.Iterator?
    private let task: URLSessionTask
    private var reading = false

    init(bytes: URLSession.AsyncBytes) { iterator = bytes.makeAsyncIterator(); task = bytes.task }

    func read() async throws -> Data? {
        guard !reading else { throw APIError.transport(.streamReadInProgress) }
        guard var current = iterator else { return nil }
        reading = true
        defer { reading = false }
        return try await withTaskCancellationHandler {
            do {
                // AsyncBytes already buffers internally. Do not wait for a full chunk: a single
                // quiet log byte must be delivered immediately rather than waiting for more IO.
                let byte = try await current.next()
                iterator = byte == nil ? nil : current
                if byte == nil { task.cancel() }
                return byte.map { Data([$0]) }
            } catch {
                iterator = nil
                task.cancel()
                throw transportError(error)
            }
        } onCancel: { self.task.cancel() }
    }

    nonisolated func cancel() { task.cancel() }
    deinit { task.cancel() }
}
