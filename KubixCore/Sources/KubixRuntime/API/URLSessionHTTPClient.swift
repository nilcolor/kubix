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
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.timeoutIntervalForRequest = policy.idleTimeout
        configuration.timeoutIntervalForResource = policy.totalTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        // One tab can follow a deployment's pods, which is one stream each. See
        // `TransportPolicy.maximumConcurrentLogStreams` for why this is set rather than inherited.
        if purpose == .logs {
            configuration.httpMaximumConnectionsPerHost = TransportPolicy.maximumConcurrentLogStreams
        }
        return configuration
    }
}

public final class URLSessionHTTPClient: TransportSession, Sendable {
    private let session: URLSession
    private let trust: ClusterTrustPolicy
    private let suspendBetweenReads: Bool

    public init(purpose: TransportPurpose, trust: ClusterTrustPolicy) {
        self.trust = trust
        suspendBetweenReads = purpose == .logs || purpose == .request
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
            return HTTPDataResponse(
                statusCode: response.statusCode, body: data, retryAfter: response.value(forHTTPHeaderField: "Retry-After")
            )
        } catch {
            #if DEBUG
            trust.recordValidationError(error)
            #endif
            throw delegate.authenticationFailure ?? transportError(error)
        }
    }

    public func stream(for request: URLRequest) async throws -> HTTPStreamResponse {
        let delegate = ClusterTrustDelegate(policy: trust)
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            guard let response = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw APIError.transport(.invalidResponse)
            }
            return HTTPStreamResponse(
                statusCode: response.statusCode, body: URLSessionByteStream(bytes: bytes, suspendBetweenReads: suspendBetweenReads),
                retryAfter: response.value(forHTTPHeaderField: "Retry-After")
            )
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
    private let suspendBetweenReads: Bool

    init(bytes: URLSession.AsyncBytes, suspendBetweenReads: Bool) {
        iterator = bytes.makeAsyncIterator()
        task = bytes.task
        self.suspendBetweenReads = suspendBetweenReads
        if suspendBetweenReads { task.suspend() }
    }

    func read() async throws -> Data? {
        guard !reading else { throw APIError.transport(.streamReadInProgress) }
        guard var current = iterator else { return nil }
        reading = true
        if suspendBetweenReads { task.resume() }
        defer {
            reading = false
            // AsyncBytes offers no configurable queue size. Stop further ingress while the
            // log consumer/UI is backpressured instead of buffering an entire fast response.
            if suspendBetweenReads, iterator != nil { task.suspend() }
        }
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
