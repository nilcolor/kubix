import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

private func rowTable(_ count: Int, continuation: String = "") -> Data {
    let rows = Array(repeating: #"{"cells":["x"]}"#, count: count).joined(separator: ",")
    return Data("""
    {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"1","continue":"\(continuation)"},
     "columnDefinitions":[{"name":"Name","type":"string"}],"rows":[\(rows)]}
    """.utf8)
}

private func list(_ items: [String], continuation: String = "") -> Data {
    Data(#"{"kind":"List","apiVersion":"v1","metadata":{"continue":"\#(continuation)"},"items":[\#(items.joined(separator: ","))]}"#.utf8)
}

private func query(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

@Suite struct ClusterOverviewServiceTests {
    private func service(_ session: ScriptedTransportSession) async throws -> ClusterOverviewService {
        let transport = try await testTransport(session: session)
        return ClusterOverviewService { _ in transport }
    }

    /// Pods are counted by phase on the server: no pod object crosses the wire, only a row per pod.
    @Test func podsAreCountedPerPhaseFromObjectlessClusterWideTables() async throws {
        let counts = ["Pending": 2, "Running": 5, "Succeeded": 3, "Failed": 1, "Unknown": 1]
        let session = ScriptedTransportSession { request, _ in
            let phase = String(query(request)["fieldSelector"]?.split(separator: "=").last ?? "")
            return HTTPDataResponse(statusCode: 200, body: rowTable(counts[phase] ?? 0))
        }
        let result = try await service(session).workloads(.pods, context: try transportConfiguration().resolve())
        #expect(result == WorkloadCounts(total: 12, running: 5, succeeded: 3, pending: 2, failed: 1))

        let requests = await session.requests
        #expect(requests.count == 5)
        for request in requests {
            #expect(request.url?.path == "/api/v1/pods")
            #expect(request.value(forHTTPHeaderField: "Accept") == APIRequest.tableAccept)
            #expect(query(request)["includeObject"] == "None")
            #expect(query(request)["limit"] == "500")
        }
        #expect(Set(requests.compactMap { query($0)["fieldSelector"] }) == Set(counts.keys.map { "status.phase=\($0)" }))
    }

    @Test func warningEventsFollowTheCursorAndCountEveryPage() async throws {
        let session = ScriptedTransportSession { _, call in
            HTTPDataResponse(statusCode: 200, body: call == 1 ? rowTable(500, continuation: "next") : rowTable(3))
        }
        #expect(try await service(session).warningEvents(context: try transportConfiguration().resolve()) == 503)
        let requests = await session.requests
        #expect(requests.map { $0.url?.path } == ["/api/v1/events", "/api/v1/events"])
        #expect(query(requests[0])["fieldSelector"] == "type=Warning")
        #expect(query(requests[0])["continue"] == nil)
        #expect(query(requests[1])["continue"] == "next")
    }

    @Test(arguments: [
        (WorkloadKind.deployments, "/apis/apps/v1/deployments"), (.daemonSets, "/apis/apps/v1/daemonsets"),
        (.statefulSets, "/apis/apps/v1/statefulsets"), (.jobs, "/apis/batch/v1/jobs"),
        (.cronJobs, "/apis/batch/v1/cronjobs"),
    ])
    func workloadKindsAreClusterWidePlainJSONLists(_ kind: WorkloadKind, _ path: String) async throws {
        let session = ScriptedTransportSession { _, _ in HTTPDataResponse(statusCode: 200, body: list(["{}"])) }
        let result = try await service(session).workloads(kind, context: try transportConfiguration().resolve())
        #expect(result.total == 1)
        let requests = await session.requests
        #expect(requests.map { $0.url?.path } == [path])
        #expect(requests[0].value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func deploymentsAreTalliedAcrossPages() async throws {
        let session = ScriptedTransportSession { _, call in
            HTTPDataResponse(statusCode: 200, body: call == 1
                ? list([#"{"spec":{"replicas":1},"status":{"readyReplicas":1}}"#], continuation: "page-2")
                : list([#"{"spec":{"replicas":2},"status":{"readyReplicas":1}}"#]))
        }
        let result = try await service(session).workloads(.deployments, context: try transportConfiguration().resolve())
        #expect(result == WorkloadCounts(total: 2, running: 1, pending: 1, failed: 0))
    }

    @Test func nodesCountReadyFromConditions() async throws {
        let session = ScriptedTransportSession { _, _ in
            HTTPDataResponse(statusCode: 200, body: list([
                #"{"status":{"conditions":[{"type":"Ready","status":"True"}]}}"#,
                #"{"status":{"conditions":[{"type":"Ready","status":"False"}]}}"#,
            ]))
        }
        #expect(try await service(session).nodes(context: try transportConfiguration().resolve()) == NodeCounts(total: 2, ready: 1))
        #expect(await session.requests.map { $0.url?.path } == ["/api/v1/nodes"])
    }

    /// The server writes `"items": null` for an empty list.
    @Test func aNullItemListIsEmpty() async throws {
        let session = ScriptedTransportSession { _, _ in
            HTTPDataResponse(statusCode: 200, body: Data(#"{"kind":"List","metadata":{},"items":null}"#.utf8))
        }
        let result = try await service(session).workloads(.jobs, context: try transportConfiguration().resolve())
        #expect(result == WorkloadCounts.empty(.jobs))
    }

    /// A count over a truncated list is a wrong number.
    @Test func anEndlessCursorThrowsRatherThanUndercounting() async throws {
        let session = ScriptedTransportSession { _, call in
            HTTPDataResponse(statusCode: 200, body: rowTable(1, continuation: "more-\(call)"))
        }
        await #expect(throws: ClusterOverviewFailure.tooManyPages) {
            _ = try await service(session).warningEvents(context: try transportConfiguration().resolve())
        }
        #expect(await session.requests.count == ClusterOverviewService.pageLimit)
    }

    @Test func aRepeatedCursorIsMalformed() async throws {
        let session = ScriptedTransportSession { _, _ in HTTPDataResponse(statusCode: 200, body: rowTable(1, continuation: "same")) }
        await #expect(throws: ClusterOverviewFailure.malformed) {
            _ = try await service(session).warningEvents(context: try transportConfiguration().resolve())
        }
        #expect(await session.requests.count == 2)
    }

    @Test func aDeniedListSurfacesTheStatusCode() async throws {
        let session = ScriptedTransportSession { _, _ in HTTPDataResponse(statusCode: 403, body: Data()) }
        do {
            _ = try await service(session).nodes(context: try transportConfiguration().resolve())
            Issue.record("expected a 403")
        } catch {
            #expect((error as? APIError)?.httpCode == 403)
        }
    }
}
