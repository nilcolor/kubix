import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

private func namespaceTable(_ names: [String], continuation: String = "") -> Data {
    let rows = names.map {
        #"{"cells":["\#($0)","Active","9d"],"object":{"metadata":{"name":"\#($0)","uid":"uid-\#($0)"}}}"#
    }
    return Data("""
    {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"1","continue":"\(continuation)"},
     "columnDefinitions":[{"name":"Name","type":"string"},{"name":"Status","type":"string"},{"name":"Age","type":"string"}],
     "rows":[\(rows.joined(separator: ","))]}
    """.utf8)
}

@Suite struct NamespaceListServiceTests {
    @Test func realAuthenticatedTransportRequestsTheUnnamespacedNamespaceTable() async throws {
        let context = try transportConfiguration().resolve()
        let credentials = TransportCredentials()
        let session = ScriptedTransportSession { _, _ in
            HTTPDataResponse(statusCode: 200, body: namespaceTable(["team", "other"]))
        }
        let transport = try await testTransport(session: session, credentials: credentials)
        let service = NamespaceListService { captured in
            #expect(captured == context)
            return transport
        }

        #expect(try await service.namespaces(context: context) == ["team", "other"])

        let requests = await session.requests
        #expect(requests.count == 1)
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].url?.path == "/api/v1/namespaces")
        #expect(requests[0].value(forHTTPHeaderField: "Accept") == APIRequest.tableAccept)
        #expect(requests[0].url?.query?.contains("includeObject=Metadata") == true)
        #expect(await credentials.acquisitions == 1)
        #expect(await session.streamRequests.isEmpty)
    }

    @Test func aCursorIsFollowedAndNamesAccumulateInOrder() async throws {
        let session = ScriptedTransportSession { _, call in
            call == 1
                ? HTTPDataResponse(statusCode: 200, body: namespaceTable(["a", "b"], continuation: "next"))
                : HTTPDataResponse(statusCode: 200, body: namespaceTable(["c"]))
        }
        let service = NamespaceListService { [transport = try await testTransport(session: session)] _ in transport }
        #expect(try await service.namespaces(context: try transportConfiguration().resolve()) == ["a", "b", "c"])
        let queries = await session.requests.map { $0.url?.query ?? "" }
        #expect(queries[0].contains("continue") == false)
        #expect(queries[1].contains("continue=next"))
    }

    @Test func aRowWithoutAMetadataNameIsSkippedRatherThanFailingTheList() async throws {
        let body = Data("""
        {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"1"},
         "columnDefinitions":[{"name":"Name","type":"string"}],
         "rows":[{"cells":["team"],"object":{"metadata":{"name":"team","uid":"uid-1"}}},
                 {"cells":["nameless"]},
                 {"cells":["other"],"object":{"metadata":{"uid":"uid-2"}}}]}
        """.utf8)
        let session = ScriptedTransportSession { _, _ in HTTPDataResponse(statusCode: 200, body: body) }
        let service = NamespaceListService { [transport = try await testTransport(session: session)] _ in transport }
        #expect(try await service.namespaces(context: try transportConfiguration().resolve()) == ["team"])
    }

    /// A cursor that never ends must not be followed forever, and a silently truncated list must not be
    /// mistaken for a complete one — the caller replaces local history with a complete list.
    @Test func anEndlessCursorThrowsRatherThanReturningATruncatedList() async throws {
        let session = ScriptedTransportSession { _, call in
            HTTPDataResponse(statusCode: 200, body: namespaceTable(["ns-\(call)"], continuation: "more-\(call)"))
        }
        let service = NamespaceListService { [transport = try await testTransport(session: session)] _ in transport }
        await #expect(throws: NamespaceListFailure.tooManyPages) {
            _ = try await service.namespaces(context: try transportConfiguration().resolve())
        }
        #expect(await session.requests.count == NamespaceListService.pageLimit)
    }

    /// A server repeating a continuation token would otherwise be followed until the page budget ran
    /// out, spending 16 requests to learn nothing.
    @Test func aRepeatedCursorIsRejectedAsMalformedOnTheSecondPage() async throws {
        let session = ScriptedTransportSession { _, _ in
            HTTPDataResponse(statusCode: 200, body: namespaceTable(["team"], continuation: "same"))
        }
        let service = NamespaceListService { [transport = try await testTransport(session: session)] _ in transport }
        await #expect(throws: NamespaceListFailure.malformed) {
            _ = try await service.namespaces(context: try transportConfiguration().resolve())
        }
        #expect(await session.requests.count == 2)
    }

    @Test func aMalformedBodyIsRejectedRatherThanReadAsAnEmptyCluster() async throws {
        let session = ScriptedTransportSession { _, _ in
            HTTPDataResponse(statusCode: 200, body: Data("not a table".utf8))
        }
        let service = NamespaceListService { [transport = try await testTransport(session: session)] _ in transport }
        await #expect(throws: NamespaceListFailure.malformed) {
            _ = try await service.namespaces(context: try transportConfiguration().resolve())
        }
    }

    @Test(arguments: [403, 401, 500])
    func statusFailuresReachTheCaller(_ code: Int) async throws {
        let session = ScriptedTransportSession { _, _ in
            HTTPDataResponse(statusCode: code, body: Data("""
            {"apiVersion":"v1","kind":"Status","reason":"Forbidden","message":"no list for you"}
            """.utf8))
        }
        let service = NamespaceListService { [transport = try await testTransport(session: session)] _ in transport }
        do {
            _ = try await service.namespaces(context: try transportConfiguration().resolve())
            Issue.record("HTTP failure was accepted as a namespace list")
        } catch let error as APIError {
            #expect(error.httpCode == code)
        }
    }

    @Test func cancellationBeforeTheRequestMakesNoRequest() async throws {
        let session = ScriptedTransportSession()
        let transport = try await testTransport(session: session)
        let service = NamespaceListService { _ in transport }
        let context = try transportConfiguration().resolve()
        let task = Task { try await service.namespaces(context: context) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await session.requests.isEmpty)
    }
}
