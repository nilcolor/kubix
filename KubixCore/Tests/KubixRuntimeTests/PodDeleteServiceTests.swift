import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

func deletePreconditionUID(_ body: Data?) throws -> String? {
    let object = try JSONSerialization.jsonObject(with: try #require(body)) as? [String: Any]
    #expect(object?["apiVersion"] as? String == "v1" && object?["kind"] as? String == "DeleteOptions")
    return (object?["preconditions"] as? [String: Any])?["uid"] as? String
}

@Suite struct PodDeleteServiceTests {
    @Test func realAuthenticatedTransportSendsOneUIDPreconditionedDELETE() async throws {
        let context = try transportConfiguration().resolve()
        let session = ScriptedTransportSession { _, _ in HTTPDataResponse(statusCode: 200, body: try podDetailsData()) }
        let transport = try await testTransport(session: session)
        let service = PodDeleteService { captured in #expect(captured == context); return transport }
        try await service.delete(context: context, namespace: "team", name: "pod-0", uid: "uid-0")
        let requests = await session.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://synthetic.invalid/api/v1/namespaces/team/pods/pod-0")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token-0")
        #expect(try deletePreconditionUID(request.httpBody) == "uid-0")
        #expect(await session.streamRequests.isEmpty)
        #expect(await session.socketRequests.isEmpty)
    }

    /// 409 is how the apiserver refuses a UID precondition: the name now belongs to a replacement.
    @Test(arguments: [403, 404, 409])
    func refusalSurvivesAsItsStatusAndIsNotRetried(_ code: Int) async throws {
        let session = ScriptedTransportSession { _, _ in
            HTTPDataResponse(statusCode: code, body: Data(#"{"apiVersion":"v1","kind":"Status","reason":"Synthetic"}"#.utf8))
        }
        let transport = try await testTransport(session: session)
        let service = PodDeleteService { _ in transport }
        do {
            try await service.delete(context: transportConfiguration().resolve(), namespace: "team", name: "pod-0", uid: "uid-0")
            Issue.record("A refused delete was accepted")
        } catch let error as APIError {
            #expect(error.httpCode == code)
        }
        #expect(await session.requests.count == 1)
    }

    @Test(arguments: ["", ".", "..", "pod/name", "nul\u{0}"])
    func invalidNameNeverAcquiresTransport(_ name: String) async throws {
        let service = PodDeleteService { _ in Issue.record("Invalid target acquired transport"); throw APIError.invalidRequest }
        await #expect(throws: APIError.invalidRequest) {
            try await service.delete(context: transportConfiguration().resolve(), namespace: "team", name: name, uid: "uid-0")
        }
    }

    @Test func missingUIDNeverAcquiresTransport() async throws {
        let service = PodDeleteService { _ in Issue.record("Unconditioned delete acquired transport"); throw APIError.invalidRequest }
        await #expect(throws: APIError.invalidRequest) {
            try await service.delete(context: transportConfiguration().resolve(), namespace: "team", name: "pod-0", uid: "")
        }
    }
}
