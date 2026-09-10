import Foundation
import KubixCore

/// One activated context, one provider (normally AuthenticationService), one TLS policy.
/// No transport entry point starts browser login. The UI explicitly owns that action.
public final class URLSessionTransport: Transport, Sendable {
    public static let execProtocol = "v5.channel.k8s.io"
    public let securityWarning: String?
    private let context: ResolvedContext
    private let credentials: any CredentialProviding
    private let sessions: [TransportPurpose: any TransportSession]
    private let clock: any TransportClock

    /// The required warning sink prevents silently enabling insecure TLS in app composition.
    public init(
        context: ResolvedContext, credentials: any CredentialProviding,
        materials: any AuthMaterialReading = LocalAuthMaterialReader(),
        factory: any TransportSessionFactory = URLSessionFactory(),
        clock: any TransportClock = ContinuousTransportClock(),
        warning: @Sendable (String) -> Void
    ) async throws {
        try Self.gate(context.cluster)
        let trust = try await ClusterTrustPolicy.load(cluster: context.cluster, materials: materials)
        try Task.checkCancellation()
        self.context = context
        self.credentials = credentials
        self.clock = clock
        securityWarning = trust.warning
        if let securityWarning { warning(securityWarning) }
        sessions = Dictionary(uniqueKeysWithValues: TransportPurpose.allCases.map {
            ($0, factory.make(purpose: $0, trust: trust))
        })
    }

    /// Accept unresolved configuration only at the activation gate; proxy rejection precedes
    /// material reads, provider acquisition and even session creation.
    public static func activate(
        configuration: Kubeconfig, contextName: String? = nil, credentials: any CredentialProviding,
        materials: any AuthMaterialReading = LocalAuthMaterialReader(),
        factory: any TransportSessionFactory = URLSessionFactory(),
        clock: any TransportClock = ContinuousTransportClock(), warning: @Sendable (String) -> Void
    ) async throws -> URLSessionTransport {
        try await Self(
            context: configuration.resolve(context: contextName), credentials: credentials,
            materials: materials, factory: factory, clock: clock, warning: warning
        )
    }

    public func data(for request: APIRequest) async throws -> Data {
        try Self.gate(context.cluster)
        return try await authenticated(managed: request.managesCredentialRefresh) { acquired in
            let outgoing = try self.authorize(request, purpose: .request, acquired: acquired)
            let response: HTTPDataResponse
            do {
                response = try await withTransportDeadline(
                    until: self.clock.now + TransportPolicy.policy(for: .request).totalTimeout, clock: self.clock
                ) { try await self.session(.request).data(for: outgoing) }
            } catch { throw transportError(error) }
            guard (200..<300).contains(response.statusCode) else {
                throw self.responseError(response.statusCode, response.body, request, acquired, retryAfter: response.retryAfter)
            }
            return response.body
        }
    }

    public func stream(for request: APIRequest, purpose: TransportPurpose) async throws -> any HTTPByteStream {
        try Self.gate(context.cluster)
        guard purpose != .webSocket else { throw APIError.invalidRequest }
        return try await authenticated(managed: request.managesCredentialRefresh) { acquired in
            let outgoing = try self.authorize(request, purpose: purpose, acquired: acquired)
            let policy = TransportPolicy.policy(for: purpose)
            let started = self.clock.now
            let response: HTTPStreamResponse
            do {
                response = try await withTransportDeadline(
                    until: started + min(policy.idleTimeout, policy.totalTimeout), clock: self.clock
                ) {
                    let response = try await self.session(purpose).stream(for: outgoing)
                    if Task.isCancelled { response.body.cancel(); throw CancellationError() }
                    return response
                }
            } catch { throw transportError(error) }
            let stream = PolicyByteStream(underlying: response.body, policy: policy, started: started, clock: self.clock)
            guard (200..<300).contains(response.statusCode) else {
                // A 401 need not wait for a possibly endless error body before refreshing.
                if response.statusCode == 401 {
                    stream.cancel()
                    throw self.responseError(response.statusCode, Data(), request, acquired)
                }
                let body = try await self.errorBody(stream)
                throw self.responseError(response.statusCode, body, request, acquired, retryAfter: response.retryAfter)
            }
            if Task.isCancelled { stream.cancel(); throw CancellationError() }
            return CredentialByteStream(underlying: stream, identity: acquired.identity, generation: acquired.entry?.generation)
        }
    }

    public func webSocket(for request: APIRequest) async throws -> any WebSocketConnection {
        try Self.gate(context.cluster)
        let connection: any WebSocketConnection = try await authenticated { acquired in
            var outgoing = try self.authorize(request, purpose: .webSocket, acquired: acquired)
            outgoing.setValue(Self.execProtocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
            do {
                // Acquisition is outside this budget, including any explicit browser-login wait.
                return try await withTransportDeadline(
                    until: self.clock.now + TransportPolicy.upgradeTimeout, clock: self.clock, failure: .upgradeTimedOut
                ) { [outgoing] in
                    let connection = try await self.session(.webSocket).connect(request: outgoing)
                    if Task.isCancelled { connection.cancel(); throw CancellationError() }
                    return connection
                }
            } catch let handshake as WebSocketHandshakeError {
                throw self.responseError(handshake.statusCode, handshake.body, request, acquired)
            } catch { throw transportError(error) }
        }
        guard connection.negotiatedProtocol == Self.execProtocol else {
            connection.cancel()
            throw APIError.unsupportedProtocol
        }
        if Task.isCancelled { connection.cancel(); throw CancellationError() }
        return HeartbeatWebSocket(connection: connection, clock: clock)
    }

    public func invalidateCredentials(after error: APIError) async throws {
        try Task.checkCancellation()
        guard case .credentialRejected(_, let identity, let generation) = error,
              identity == (try CredentialIdentity(from: context)) else {
            throw APIError.credentialsExhausted(error)
        }
        await credentials.invalidate(identity, failedGeneration: generation)
        try Task.checkCancellation()
    }

    private func authenticated<Value: Sendable>(
        managed: Bool = false,
        _ operation: (AcquiredCredential) async throws -> Value
    ) async throws -> Value {
        for attempt in 0...1 {
            try Task.checkCancellation()
            let acquired = try await credentials.acquire(for: context)
            try Task.checkCancellation()
            do { return try await operation(acquired) } catch let error as APIError {
                guard error.httpCode == 401 else { throw error }
                if managed {
                    guard let entry = acquired.entry else { throw APIError.credentialsExhausted(error) }
                    throw APIError.credentialRejected(error, identity: acquired.identity, generation: entry.generation)
                }
                guard attempt == 0 else { throw APIError.credentialsExhausted(error) }
                if let entry = acquired.entry {
                    await credentials.invalidate(acquired.identity, failedGeneration: entry.generation)
                }
            }
        }
        throw APIError.transport(.connection)
    }

    private func authorize(
        _ request: APIRequest, purpose: TransportPurpose, acquired: AcquiredCredential
    ) throws -> URLRequest {
        guard let base = URL(string: context.cluster.server) else { throw APIError.invalidRequest }
        var outgoing = try request.urlRequest(baseURL: base, purpose: purpose)
        if let credential = acquired.entry?.credential {
            guard credential.clientCertificateData == nil else { throw AuthenticationError.unsupportedCertificate }
            if let token = credential.token { outgoing.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        }
        if context.cluster.disableCompression == true { outgoing.setValue("identity", forHTTPHeaderField: "Accept-Encoding") }
        return outgoing
    }

    private func responseError(
        _ code: Int, _ body: Data, _ request: APIRequest, _ acquired: AcquiredCredential, retryAfter: String? = nil
    ) -> APIError {
        .response(
            code: code, body: body, resource: request.resourceContext,
            redacting: acquired.entry?.credential.token, retryAfter: retryAfter
        )
    }

    private func errorBody(_ stream: any HTTPByteStream) async throws -> Data {
        defer { stream.cancel() }
        do {
            return try await withTransportDeadline(until: clock.now + 30, clock: clock, cancel: stream.cancel) {
                var body = Data()
                while let chunk = try await stream.read() {
                    guard body.count + chunk.count <= 65_536 else { return Data() }
                    body.append(chunk)
                }
                return body
            }
        } catch is CancellationError { throw CancellationError() } catch { return Data() }
    }

    private func session(_ purpose: TransportPurpose) -> any TransportSession {
        // The immutable dictionary is built from all enum cases at initialization.
        sessions[purpose]!
    }

    private static func gate(_ cluster: KubeconfigCluster) throws {
        if let proxy = cluster.proxyURL, !proxy.isEmpty { throw KubeconfigError.unsupportedProxy }
    }
}
