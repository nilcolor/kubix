import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

func podDetailsData(
    uid: String = "uid-0", name: String = "pod-0", namespace: String = "team",
    running: [String] = ["web"], annotation: String = "web"
) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "apiVersion": "v1", "kind": "Pod",
        "metadata": ["uid": uid, "name": name, "namespace": namespace,
                     "annotations": ["kubectl.kubernetes.io/default-container": annotation]],
        "spec": [
            "containers": running.map { ["name": $0] } + [["name": "waiting"]],
            "initContainers": [["name": "setup"]], "ephemeralContainers": [["name": "debugger"]],
        ],
        "status": [
            "containerStatuses": running.map { ["name": $0, "state": ["running": [:]]] as [String: Any] },
            "initContainerStatuses": [["name": "setup", "state": ["running": [:]]]],
            "ephemeralContainerStatuses": [["name": "debugger", "state": ["running": [:]]]],
        ],
    ])
}

@Suite struct PodDetailsServiceTests {
    @Test func realAuthenticatedTransportUsesFreshPlainJSONGETAndExactContextPath() async throws {
        let context = try transportConfiguration().resolve()
        let credentials = TransportCredentials()
        let session = ScriptedTransportSession { _, _ in
            HTTPDataResponse(statusCode: 200, body: try podDetailsData())
        }
        let transport = try await testTransport(session: session, credentials: credentials)
        let service = PodDetailsService { captured in #expect(captured == context); return transport }
        for _ in 0..<2 {
            let details = try await service.details(context: context, namespace: "team", name: "pod-0", uid: "uid-0")
            #expect(details.uid == "uid-0" && details.containers.count == 4)
        }
        let requests = await session.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.httpMethod == "GET")
            #expect(request.url?.absoluteString == "https://synthetic.invalid/api/v1/namespaces/team/pods/pod-0")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token-0")
        }
        #expect(await credentials.acquisitions == 2)
        #expect(await session.streamRequests.isEmpty)
        #expect(await session.socketRequests.isEmpty)
    }

    @Test(arguments: [403, 404, 401])
    func transportStatusSurvivesWithoutRawBody(_ code: Int) async throws {
        let session = ScriptedTransportSession { _, _ in
            HTTPDataResponse(statusCode: code, body: Data("""
            {"apiVersion":"v1","kind":"Status","reason":"Synthetic","message":"synthetic-token-0"}
            """.utf8))
        }
        let transport = try await testTransport(session: session)
        let service = PodDetailsService { _ in transport }
        do {
            _ = try await service.details(context: transportConfiguration().resolve(), namespace: "team", name: "pod-0", uid: "uid-0")
            Issue.record("HTTP failure was accepted")
        } catch let error as APIError {
            #expect(error.httpCode == code)
            #expect(error.credentialRefreshExhausted == (code == 401))
            if code != 401 { #expect(error.kubernetesStatus?.message == "[redacted]") }
        }
        #expect(await session.requests.count == (code == 401 ? 2 : 1))
    }

    @Test(arguments: ["uid", "name", "namespace", "malformed"])
    func rejectsRecreatedMismatchedOrMalformedPod(_ field: String) async throws {
        let transport = WatchTestTransport { _, _ in
            if field == "malformed" { return Data("{}".utf8) }
            return try podDetailsData(
                uid: field == "uid" ? "replacement" : "uid-0",
                name: field == "name" ? "other" : "pod-0", namespace: field == "namespace" ? "other" : "team"
            )
        }
        let service = PodDetailsService { _ in transport }
        let expected: PodDetailsError = field == "uid" ? .replaced : field == "malformed" ? .malformed : .identityMismatch
        await #expect(throws: expected) {
            _ = try await service.details(context: transportConfiguration().resolve(), namespace: "team", name: "pod-0", uid: "uid-0")
        }
    }

    @Test(arguments: [true, false])
    func cancellationDiscardsUncooperativeFactoryOrResponse(factory: Bool) async throws {
        let gate = UncooperativeWatchGate()
        let transport = WatchTestTransport { _, _ in
            if !factory { await gate.wait() }
            return try podDetailsData()
        }
        let service = PodDetailsService { _ in
            if factory { await gate.wait() }
            return transport
        }
        let task = Task {
            try await service.details(context: transportConfiguration().resolve(), namespace: "team", name: "pod-0", uid: "uid-0")
        }
        try await transportEventually { await gate.isWaiting }
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await transport.requests.count == (factory ? 0 : 1))
    }

    @Test func cancellationDuringTransportAuthenticationSendsNoGET() async throws {
        let gate = TestGate()
        let credentials = TransportCredentials(gate: gate)
        let session = ScriptedTransportSession()
        let transport = try await testTransport(session: session, credentials: credentials)
        let service = PodDetailsService { _ in transport }
        let task = Task {
            try await service.details(context: transportConfiguration().resolve(), namespace: "team", name: "pod-0", uid: "uid-0")
        }
        try await transportEventually { await credentials.acquisitions == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await session.requests.isEmpty)
    }

    @Test(arguments: ["", ".", "..", "pod/name", "nul\u{0}"])
    func invalidNameNeverAcquiresTransport(_ name: String) async throws {
        let service = PodDetailsService { _ in Issue.record("Invalid target acquired transport"); throw APIError.invalidRequest }
        await #expect(throws: APIError.invalidRequest) {
            _ = try await service.details(context: transportConfiguration().resolve(), namespace: "team", name: name, uid: "uid-0")
        }
    }

    @Test(arguments: ["", "Bad/namespace"])
    func invalidNamespaceNeverAcquiresTransport(_ namespace: String) async throws {
        let service = PodDetailsService { _ in Issue.record("Invalid namespace acquired transport"); throw APIError.invalidRequest }
        await #expect(throws: APIError.invalidRequest) {
            _ = try await service.details(context: transportConfiguration().resolve(), namespace: namespace, name: "pod-0", uid: "uid-0")
        }
    }

    @Test func missingUIDAndPreCancelledRequestNeverAcquireTransport() async throws {
        let service = PodDetailsService { _ in Issue.record("Invalid or cancelled selection acquired transport"); throw APIError.invalidRequest }
        await #expect(throws: APIError.invalidRequest) {
            _ = try await service.details(context: transportConfiguration().resolve(), namespace: "team", name: "pod-0", uid: "")
        }
        let gate = UncooperativeWatchGate()
        let task = Task {
            await gate.wait()
            return try await service.details(context: transportConfiguration().resolve(), namespace: "team", name: "pod-0", uid: "uid-0")
        }
        try await transportEventually { await gate.isWaiting }
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
