import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Suite struct ClusterProbeServiceTests {
    @Test func realAuthenticatedTransportGETsTheUnnamespacedVersionPathOncePerProbe() async throws {
        let context = try transportConfiguration().resolve()
        let credentials = TransportCredentials()
        let session = ScriptedTransportSession { _, _ in
            HTTPDataResponse(statusCode: 200, body: Data(#"{"gitVersion":"v1.29.4"}"#.utf8))
        }
        let transport = try await testTransport(session: session, credentials: credentials)
        let factories = FactoryCount()
        let service = ClusterProbeService { captured in
            #expect(captured == context)
            await factories.increment()
            return transport
        }

        #expect(try await service.probe(context: context) == "v1.29.4")
        #expect(try await service.probe(context: context) == "v1.29.4")

        #expect(await factories.value == 2)
        let requests = await session.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.httpMethod == "GET")
            #expect(request.url?.absoluteString == "https://synthetic.invalid/version")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token-0")
        }
        #expect(await credentials.acquisitions == 2)
        #expect(await session.streamRequests.isEmpty)
        #expect(await session.socketRequests.isEmpty)
    }

    @Test func anUnreadableBodyStillMeansReachableWithoutAVersion() async throws {
        let session = ScriptedTransportSession { _, _ in
            HTTPDataResponse(statusCode: 200, body: Data("not json at all".utf8))
        }
        let service = ClusterProbeService { [transport = try await testTransport(session: session)] _ in transport }
        // A server that answers is reachable; only the displayed version is missing.
        #expect(try await service.probe(context: try transportConfiguration().resolve()) == nil)
        #expect(await session.requests.count == 1)
    }

    @Test(arguments: [401, 403, 500])
    func statusFailuresCarryTheCodeAndRedactACredentialEcho(_ code: Int) async throws {
        let session = ScriptedTransportSession { _, _ in
            HTTPDataResponse(statusCode: code, body: Data("""
            {"apiVersion":"v1","kind":"Status","reason":"Forbidden","message":"denied synthetic-token-0"}
            """.utf8))
        }
        let service = ClusterProbeService { [transport = try await testTransport(session: session)] _ in transport }
        do {
            _ = try await service.probe(context: try transportConfiguration().resolve())
            Issue.record("HTTP failure was accepted as reachable")
        } catch let error as APIError {
            #expect(error.httpCode == code)
            #expect(error.credentialRefreshExhausted == (code == 401))
            // A 401 is re-attempted with a refreshed credential and redacts against that one, so an
            // echo of the rejected token survives. Pre-existing and not probe-specific; tracked in
            // docs/backlog/retry-redacts-against-the-wrong-token.md.
            #expect(error.kubernetesStatus?.message == (code == 401 ? "denied synthetic-token-0" : "denied [redacted]"))
        }
        // 401 spends its one credential refresh before giving up, exactly as a pod request does.
        #expect(await session.requests.count == (code == 401 ? 2 : 1))
    }

    @Test func anErrorPageIsNotRetainedAtAll() async throws {
        let session = ScriptedTransportSession { _, _ in
            HTTPDataResponse(statusCode: 502, body: Data("<html><body>proxy denied synthetic-token-0</body></html>".utf8))
        }
        let service = ClusterProbeService { [transport = try await testTransport(session: session)] _ in transport }
        do {
            _ = try await service.probe(context: try transportConfiguration().resolve())
            Issue.record("HTTP failure was accepted as reachable")
        } catch let error as APIError {
            #expect(error.httpCode == 502)
            #expect(error.kubernetesStatus == nil)
            #expect(!error.description.contains("synthetic-token-0") && !error.description.contains("html"))
        }
    }

    /// A probe failure is not always an `APIError`: an unsupported client certificate is rejected on
    /// the credential path, before any request, and connect state has to be able to describe it.
    @Test func aNonAPIErrorCredentialFailureReachesTheCallerBeforeAnyRequest() async throws {
        let session = ScriptedTransportSession()
        let transport = try await testTransport(session: session, credentials: TransportCredentials(certificate: true))
        let service = ClusterProbeService { _ in transport }
        await #expect(throws: AuthenticationError.unsupportedCertificate) {
            _ = try await service.probe(context: try transportConfiguration().resolve())
        }
        #expect(await session.requests.isEmpty)
    }

    @Test func cancellationBeforeTheRequestMakesNoRequest() async throws {
        let session = ScriptedTransportSession()
        let transport = try await testTransport(session: session)
        let service = ClusterProbeService { _ in transport }
        let context = try transportConfiguration().resolve()
        let task = Task { _ = try await service.probe(context: context) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await session.requests.isEmpty)
    }
}

private actor FactoryCount {
    private(set) var value = 0
    func increment() { value += 1 }
}
