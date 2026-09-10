import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

enum TransportEntry: CaseIterable, Sendable {
    case data, stream, socket
    func run(_ transport: URLSessionTransport) async throws {
        switch self {
        case .data: _ = try await transport.data(for: podsRequest)
        case .stream: try await transport.stream(for: podsRequest, purpose: .logs).cancel()
        case .socket: try await transport.webSocket(for: execRequest).cancel()
        }
    }
}

func statusSession(_ code: Int, recover: Bool = false) -> ScriptedTransportSession {
    let status = Data("""
    {"apiVersion":"v1","kind":"Status","reason":"Forbidden","message":"synthetic error","code":\(code)}
    """.utf8)
    return ScriptedTransportSession(
        data: { _, count in HTTPDataResponse(statusCode: recover && count > 1 ? 200 : code, body: status) },
        stream: { _, count in
            HTTPStreamResponse(statusCode: recover && count > 1 ? 200 : code, body: MemoryByteStream([status], finished: true))
        },
        socket: { _, count in
            if recover && count > 1 { return TransportSocket() }
            throw WebSocketHandshakeError(statusCode: code, body: status)
        }
    )
}

@Test(arguments: TransportEntry.allCases)
func transportRetries401OnceWithNewGeneration(_ entry: TransportEntry) async throws {
    let credentials = TransportCredentials()
    let session = statusSession(401, recover: true)
    let transport = try await testTransport(session: session, credentials: credentials)
    try await entry.run(transport)
    #expect(await credentials.acquisitions == 2)
    #expect(await credentials.invalidations.count == 1)
    let requests = await session.requests + session.streamRequests + session.socketRequests
    #expect(requests.count == 2)
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token-0")
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token-1")
}

@Test(arguments: TransportEntry.allCases, [401, 403])
func transportBounds401AndNeverRetries403(_ entry: TransportEntry, code: Int) async throws {
    let credentials = TransportCredentials()
    let session = statusSession(code)
    let transport = try await testTransport(session: session, credentials: credentials)
    do {
        try await entry.run(transport)
        Issue.record("Expected HTTP error")
    } catch let error as APIError {
        #expect(error.httpCode == code)
        #expect(error.description.contains("pods"))
        if code == 403 { #expect(error.description.contains("Forbidden")) }
    }
    #expect(await credentials.acquisitions == (code == 401 ? 2 : 1))
    #expect(await credentials.invalidations.count == (code == 401 ? 1 : 0))
}

@Test func simultaneousAndLate401OnlyInvalidatesFailedGeneration() async throws {
    let credentials = TransportCredentials()
    let firstResponse = TestGate()
    let session = ScriptedTransportSession(data: { request, count in
        if count == 1 { try await firstResponse.wait() }
        let old = request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token-0"
        return HTTPDataResponse(statusCode: old ? 401 : 200, body: Data())
    })
    let transport = try await testTransport(session: session, credentials: credentials)
    let first = Task { try await transport.data(for: podsRequest) }
    try await transportEventually { await session.requests.count == 1 }
    _ = try await transport.data(for: podsRequest)
    await firstResponse.open()
    _ = try await first.value
    #expect(await credentials.acquisitions == 4)
    #expect(await credentials.acceptedInvalidations == 1)
    let generations = await credentials.invalidations
    #expect(generations.count == 2)
    #expect(generations.first == generations.last)
}

@Test(arguments: TransportEntry.allCases)
func forbiddenNeverStartsBrowserLoginThroughAuthenticationService(_ entry: TransportEntry) async throws {
    let process = FakeProcess()
    let provider = CredentialProvider(resolver: testResolver(), runner: CredentialRunner(process: process))
    let service = AuthenticationService(provider: provider, login: AWSLoginService(runner: process))
    let transport = try await URLSessionTransport(
        context: awsContext(), credentials: service, factory: RecordingSessionFactory(statusSession(403)),
        clock: ManualTransportClock(), warning: { _ in }
    )
    do { try await entry.run(transport); Issue.record("Expected forbidden") } catch let error as APIError {
        #expect(error.httpCode == 403)
    }
    let invocations = await process.requests()
    #expect(invocations.count == 1)
    #expect(invocations.first?.arguments.prefix(2) == ["eks", "get-token"])
}

@Test func allPurposesShareProviderAndExactTLSPolicy() async throws {
    let credentials = TransportCredentials()
    let factory = RecordingSessionFactory()
    let warning = TextCapture()
    let config = transportConfiguration(cluster: KubeconfigCluster(
        server: "https://synthetic.invalid/base", insecureSkipTLSVerify: true,
        tlsServerName: "synthetic.invalid", disableCompression: true
    ))
    let transport = try await URLSessionTransport.activate(
        configuration: config, credentials: credentials, factory: factory, clock: ManualTransportClock(), warning: warning.append
    )
    _ = try await transport.data(for: podsRequest)
    for purpose in [TransportPurpose.watch, .logs] { try await transport.stream(for: podsRequest, purpose: purpose).cancel() }
    try await transport.webSocket(for: execRequest).cancel()
    #expect(await credentials.acquisitions == 4)
    #expect(factory.policies.count == 4)
    let first = try #require(factory.policies.first?.1)
    #expect(factory.policies.allSatisfy { $0.1 === first && $0.1.insecureSkipTLSVerify })
    #expect(transport.securityWarning == warning.value)
    #expect(warning.value.contains("DISABLED"))
    let requests = await factory.session.requests + factory.session.streamRequests + factory.session.socketRequests
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token-0" })
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept-Encoding") == "identity" })
    #expect(requests.allSatisfy { !($0.url?.absoluteString.contains("synthetic-token") ?? true) })
    let websocket = try #require(await factory.session.socketRequests.first)
    #expect(websocket.url?.scheme == "wss")
    #expect(websocket.url?.path == "/base/api/v1/namespaces/team/pods/pod/exec")
    #expect(websocket.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "v5.channel.k8s.io")
}

@Test(arguments: TransportEntry.allCases)
func unsupportedProxyPreventsEveryEntryBeforeCredentialsMaterialsOrSessions(_ entry: TransportEntry) async throws {
    let credentials = TransportCredentials()
    let factory = RecordingSessionFactory()
    let materials = MaterialFiles()
    let config = transportConfiguration(cluster: KubeconfigCluster(
        server: "https://synthetic.invalid", certificateAuthority: "/must-not-read", proxyURL: "http://proxy.invalid"
    ))
    await #expect(throws: KubeconfigError.unsupportedProxy) {
        let transport = try await URLSessionTransport.activate(
            configuration: config, credentials: credentials, materials: materials, factory: factory, warning: { _ in }
        )
        try await entry.run(transport)
    }
    #expect(await credentials.acquisitions == 0)
    #expect(await materials.reads.isEmpty)
    #expect(factory.policies.isEmpty)
}

@Test(arguments: TransportEntry.allCases)
func certificateCredentialsRemainExplicitlyUnsupported(_ entry: TransportEntry) async throws {
    let session = ScriptedTransportSession()
    let transport = try await testTransport(session: session, credentials: TransportCredentials(certificate: true))
    await #expect(throws: AuthenticationError.unsupportedCertificate) { try await entry.run(transport) }
    #expect(await session.requests.isEmpty)
    #expect(await session.streamRequests.isEmpty)
    #expect(await session.socketRequests.isEmpty)
}

@Test func anonymousAndFailureSanitization() async throws {
    let session = ScriptedTransportSession(data: { _, _ in
        throw NSError(domain: NSURLErrorDomain, code: URLError.networkConnectionLost.rawValue,
                      userInfo: [NSLocalizedDescriptionKey: "Bearer synthetic-secret at https://private.invalid"])
    })
    let transport = try await testTransport(session: session, credentials: TransportCredentials(anonymous: true))
    await #expect(throws: APIError.transport(.connection)) { try await transport.data(for: podsRequest) }
    #expect(await session.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(await session.requests.count == 1)
    #expect(!APIError.transport(.connection).description.contains("synthetic-secret"))
}

@Test(arguments: [nil, "v4.channel.k8s.io", ""])
func protocolNegotiationMustBeV5(_ selected: String?) async throws {
    let socket = TransportSocket(protocolName: selected)
    let session = ScriptedTransportSession(socket: { _, _ in socket })
    let clock = ManualTransportClock()
    let transport = try await testTransport(session: session, clock: clock)
    await #expect(throws: APIError.unsupportedProtocol) { try await transport.webSocket(for: execRequest) }
    #expect(socket.cancelled)
    #expect(clock.deadlines.isEmpty)
    #expect(await session.socketRequests.count == 1)
}

@Test func stream401CancelsOldBodyBeforeRetry() async throws {
    let old = MemoryByteStream()
    let fresh = MemoryByteStream()
    let session = ScriptedTransportSession(stream: { _, count in
        HTTPStreamResponse(statusCode: count == 1 ? 401 : 200, body: count == 1 ? old : fresh)
    })
    let transport = try await testTransport(session: session)
    let stream = try await transport.stream(for: podsRequest, purpose: .watch)
    #expect(old.cancelled)
    #expect(!fresh.cancelled)
    stream.cancel()
    #expect(fresh.cancelled)
}

@Test func coreTransportContractAcceptsRuntimeAndMemoryImplementations() async throws {
    let runtime: any Transport = try await testTransport(session: ScriptedTransportSession())
    let memory: any Transport = InMemoryTransport(response: Data("ok".utf8), bytes: MemoryByteStream(), socket: TransportSocket())
    for transport in [runtime, memory] {
        #expect(try await transport.data(for: podsRequest) == Data("ok".utf8))
        try await transport.stream(for: podsRequest, purpose: .logs).cancel()
        try await transport.webSocket(for: execRequest).cancel()
    }
}

@Test func allEntryPointsJoinTheRealAuthenticationSingleFlight() async throws {
    let gate = TestGate()
    let process = FakeProcess { _, _ in
        try await gate.wait()
        return ProcessResult(stdout: syntheticCredential, exitCode: 0)
    }
    let provider = CredentialProvider(resolver: testResolver(), runner: CredentialRunner(process: process))
    let service = AuthenticationService(provider: provider)
    let session = ScriptedTransportSession()
    let transport = try await URLSessionTransport(
        context: runtimeContext(), credentials: service, factory: RecordingSessionFactory(session),
        clock: ManualTransportClock(), warning: { _ in }
    )
    let work = Task {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for entry in TransportEntry.allCases { group.addTask { try await entry.run(transport) } }
            try await group.waitForAll()
        }
    }
    try await transportEventually { await process.requests().count == 1 }
    await gate.open()
    try await work.value
    #expect(await process.requests().count == 1)
    let requests = await session.requests + session.streamRequests + session.socketRequests
    #expect(requests.count == 3)
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-credential-only" })
}

private struct EstablishedUnauthorizedSocket: WebSocketConnection {
    let negotiatedProtocol: String? = URLSessionTransport.execProtocol
    func send(_ data: Data) async throws {}
    func receive() async throws -> Data { throw APIError.http(code: 401, resource: "pods/exec") }
    func ping() async throws {}
    func cancel() {}
}

@Test func establishedSocketErrorIsNeverAuthenticatedOrReplayed() async throws {
    let clock = ManualTransportClock()
    let credentials = TransportCredentials()
    let session = ScriptedTransportSession(socket: { _, _ in EstablishedUnauthorizedSocket() })
    let transport = try await testTransport(session: session, credentials: credentials, clock: clock)
    let socket = try await transport.webSocket(for: execRequest)
    await #expect(throws: APIError.http(code: 401, resource: "pods/exec")) { try await socket.receive() }
    #expect(await credentials.acquisitions == 1)
    #expect(await credentials.invalidations.isEmpty)
    #expect(await session.socketRequests.count == 1)
    try await transportEventually { clock.deadlines.isEmpty }
}
