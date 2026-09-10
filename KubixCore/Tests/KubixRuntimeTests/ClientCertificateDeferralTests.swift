import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Suite struct ClientCertificateDeferralTests {
    @Test(arguments: [
        KubeconfigUser(clientCertificate: "/synthetic/cert", clientKey: "/synthetic/key"),
        KubeconfigUser(clientCertificateData: "not-base64-cert", clientKeyData: "not-base64-key"),
        KubeconfigUser(clientCertificate: "/must-not-read", clientCertificateData: "inline-cert", clientKey: "/synthetic/key"),
        KubeconfigUser(clientCertificate: "/synthetic/cert", clientKey: "/must-not-read", clientKeyData: "inline-key")
    ])
    func staticCertificatesFailBeforeMaterialReadsOrRequests(_ user: KubeconfigUser) async throws {
        let process = FakeProcess()
        let materials = MaterialFiles()
        let provider = makeProvider(process: process, materials: materials)
        let context = try runtimeContext(user: user)
        await #expect(throws: AuthenticationError.unsupportedCertificate) { try await provider.acquire(for: context) }
        let session = ScriptedTransportSession()
        let transport = try await makeTransport(context: context, provider: provider, session: session, materials: materials)
        for purpose in TransportPurpose.allCases {
            await #expect(throws: AuthenticationError.unsupportedCertificate) { try await run(transport, purpose: purpose) }
        }
        #expect(await process.requests().isEmpty)
        #expect(await materials.reads.isEmpty)
        await expectNoRequests(session)
    }

    @Test(arguments: [
        KubeconfigUser(clientCertificate: "/synthetic/cert"),
        KubeconfigUser(clientKey: "/synthetic/key"),
        KubeconfigUser(clientCertificateData: "inline-cert", clientKeyData: ""),
        KubeconfigUser(clientKeyData: "inline-key")
    ])
    func partialStaticCertificatesNeverBecomeAnonymous(_ user: KubeconfigUser) async throws {
        let process = FakeProcess()
        let materials = MaterialFiles()
        let provider = makeProvider(process: process, materials: materials)
        let context = try runtimeContext(user: user)
        await #expect(throws: AuthError.incompleteClientCertificate) { try await provider.acquire(for: context) }
        let session = ScriptedTransportSession()
        let transport = try await makeTransport(context: context, provider: provider, session: session, materials: materials)
        for purpose in TransportPurpose.allCases {
            await #expect(throws: AuthError.incompleteClientCertificate) { try await run(transport, purpose: purpose) }
        }
        #expect(await process.requests().isEmpty)
        #expect(await materials.reads.isEmpty)
        await expectNoRequests(session)
    }

    @Test(arguments: ExecCredential.APIVersion.allCases, [false, true])
    func execCertificatesRejectBeforeCachingOrRequests(_ version: ExecCredential.APIVersion, withToken: Bool) async throws {
        let token = withToken ? #""token":"synthetic-token","# : ""
        let output = Data("""
        {"apiVersion":"\(version.rawValue)","kind":"ExecCredential",
         "status":{\(token)"clientCertificateData":"not-PEM-cert","clientKeyData":"not-PEM-key"}}
        """.utf8)
        let process = FakeProcess { _, _ in ProcessResult(stdout: output, exitCode: 0) }
        let materials = MaterialFiles()
        let provider = makeProvider(process: process, materials: materials)
        var config = runtimeExec()
        config.apiVersion = version.rawValue
        let context = try runtimeContext(user: KubeconfigUser(exec: config))
        let session = ScriptedTransportSession()
        let transport = try await makeTransport(context: context, provider: provider, session: session, materials: materials)
        await #expect(throws: AuthenticationError.unsupportedCertificate) { try await provider.acquire(for: context) }
        for purpose in TransportPurpose.allCases {
            await #expect(throws: AuthenticationError.unsupportedCertificate) { try await run(transport, purpose: purpose) }
        }
        // Each rejected result requires acquisition again; none was cached or retried as a 401.
        #expect(await process.requests().count == 1 + TransportPurpose.allCases.count)
        #expect(await materials.reads.isEmpty)
        await expectNoRequests(session)
    }

    @Test(arguments: [
        (#"{"token":"synthetic-token","clientCertificateData":"cert"}"#, AuthError.incompleteClientCertificate),
        (#"{"token":"synthetic-token","clientKeyData":"key"}"#, .incompleteClientCertificate),
        (#"{"clientCertificateData":"","clientKeyData":"key"}"#, .incompleteClientCertificate),
        (#"{"clientCertificateData":"cert","clientKeyData":""}"#, .incompleteClientCertificate),
        (#"{"token":"synthetic-token","clientCertificateData":" ","clientKeyData":"key"}"#, .invalidClientCertificate),
        (#"{"token":"synthetic-token","clientCertificateData":7,"clientKeyData":"key"}"#, .malformedExecCredential),
        (#"{"clientCertificateData":"","clientKeyData":""}"#, .missingCredentials)
    ])
    func malformedExecCertificatesNeverFallBack(_ status: String, error: AuthError) async throws {
        let output = Data("""
        {"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":\(status)}
        """.utf8)
        let process = FakeProcess { _, _ in ProcessResult(stdout: output, exitCode: 0) }
        let materials = MaterialFiles()
        let provider = makeProvider(process: process, materials: materials)
        let session = ScriptedTransportSession()
        let transport = try await makeTransport(
            context: runtimeContext(), provider: provider, session: session, materials: materials
        )
        for purpose in TransportPurpose.allCases {
            await #expect(throws: error) { try await run(transport, purpose: purpose) }
        }
        #expect(await process.requests().count == TransportPurpose.allCases.count)
        #expect(await materials.reads.isEmpty)
        await expectNoRequests(session)
    }

    @Test(arguments: TransportPurpose.allCases, [false, true])
    func transportIndependentlyRejectsCertificateBearingProviders(_ purpose: TransportPurpose, withToken: Bool) async throws {
        let session = ScriptedTransportSession()
        let provider = CertificateProvider(credential: try Credential(
            token: withToken ? "synthetic-token" : nil, clientCertificateData: "cert", clientKeyData: "key"
        ))
        let transport = try await testTransport(session: session, credentials: provider)
        await #expect(throws: AuthenticationError.unsupportedCertificate) { try await run(transport, purpose: purpose) }
        await expectNoRequests(session)
    }

    @Test func rejectionMessageDescribesReleaseScopeAndBearerAlternative() {
        let message = AuthenticationError.unsupportedCertificate.localizedDescription
        #expect(message.contains("static or exec-returned"))
        #expect(message.contains("unsupported in v0.1"))
        #expect(message.contains("bearer-token"))
    }

    private func makeProvider(process: FakeProcess, materials: MaterialFiles) -> CredentialProvider {
        CredentialProvider(
            resolver: testResolver(), runner: CredentialRunner(process: process, materials: materials), materials: materials
        )
    }

    private func makeTransport(
        context: ResolvedContext, provider: CredentialProvider, session: ScriptedTransportSession, materials: MaterialFiles
    ) async throws -> URLSessionTransport {
        try await URLSessionTransport(
            context: context, credentials: provider, materials: materials,
            factory: RecordingSessionFactory(session), clock: ManualTransportClock(), warning: { _ in }
        )
    }

    private func run(_ transport: URLSessionTransport, purpose: TransportPurpose) async throws {
        switch purpose {
        case .request: _ = try await transport.data(for: podsRequest)
        case .watch, .logs: try await transport.stream(for: podsRequest, purpose: purpose).cancel()
        case .webSocket: try await transport.webSocket(for: execRequest).cancel()
        }
    }

    private func expectNoRequests(_ session: ScriptedTransportSession) async {
        #expect(await session.requests.isEmpty)
        #expect(await session.streamRequests.isEmpty)
        #expect(await session.socketRequests.isEmpty)
    }
}

private struct CertificateProvider: CredentialProviding {
    let credential: Credential
    func acquire(for context: ResolvedContext, progress: @escaping AuthProgress) throws -> AcquiredCredential {
        let identity = try CredentialIdentity(from: context)
        var cache = CredentialCache(now: { Date(timeIntervalSince1970: 1_000) })
        return AcquiredCredential(identity: identity, entry: try cache.store(credential, for: identity))
    }
    func invalidate(_ identity: CredentialIdentity, failedGeneration: CredentialCache.Generation) {
        Issue.record("Unsupported certificates must not cause credential-refresh retries.")
    }
}
