import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

private func podMetadataPage(
    _ pods: [(name: String, uid: String, created: String?)], cursor: String = "", namespace: String = "team"
) throws -> Data {
    let rows = pods.map { pod in
        let created = pod.created.map { #","creationTimestamp":"\#($0)""# } ?? ""
        return #"{"cells":["\#(pod.name)","Running","1/1","0","5m"],"object":{"metadata":{"uid":"\#(pod.uid)","name":"\#(pod.name)","namespace":"\#(namespace)"\#(created)}}}"#
    }.joined(separator: ",")
    return Data("""
    {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"1","continue":"\(cursor)"},
     "columnDefinitions":[{"name":"Name","type":"string"},{"name":"Status","type":"string"},
      {"name":"Ready","type":"string"},{"name":"Restarts","type":"string"},{"name":"Age","type":"string"}],
     "rows":[\(rows)]}
    """.utf8)
}

@Suite struct DeploymentPodServiceTests {
    private func service(
        _ body: @escaping @Sendable (APIRequest, Int) async throws -> Data
    ) -> (DeploymentPodService, WatchTestTransport) {
        let transport = WatchTestTransport(data: body)
        return (DeploymentPodService { _ in transport }, transport)
    }

    @Test func theSelectorScopesOneNamespacedMetadataTableRequest() async throws {
        let selector = try LabelSelector(["app": "web", "pod-template-hash": "7d9f"])
        let (service, transport) = service { _, _ in
            try podMetadataPage([("web-7d9f-a", "uid-a", "2026-10-01T00:00:00Z")])
        }
        let pods = try await service.pods(context: try runtimeContext(), namespace: "team", selector: selector)
        #expect(pods.map(\.name) == ["web-7d9f-a"])
        #expect(pods.map(\.uid) == ["uid-a"])
        #expect(pods.first?.created == RFC3339.date(from: "2026-10-01T00:00:00Z"))
        let request = try #require(await transport.requests.first)
        #expect(request.path == ["api", "v1", "namespaces", "team", "pods"])
        #expect(request.accept == APIRequest.tableAccept)
        #expect(podQuery(request) == [
            "limit": "500", "includeObject": "Metadata", "labelSelector": "app=web,pod-template-hash=7d9f",
        ])
    }

    /// Newest first, so a rollout's new replicas are the ones a capped set keeps.
    @Test func podsAreOrderedNewestFirstAndStablyWhenUndated() async throws {
        let (service, _) = service { _, _ in
            try podMetadataPage([
                ("older", "uid-1", "2026-10-01T00:00:00Z"),
                ("newest", "uid-2", "2026-10-05T00:00:00Z"),
                ("middle", "uid-3", "2026-10-03T00:00:00Z"),
                ("undated-b", "uid-4", nil),
                ("undated-a", "uid-5", nil),
            ])
        }
        let pods = try await service.pods(
            context: try runtimeContext(), namespace: "team", selector: try LabelSelector(["app": "web"])
        )
        #expect(pods.map(\.name) == ["newest", "middle", "older", "undated-a", "undated-b"])
    }

    @Test func aContinuationIsFollowedToTheEnd() async throws {
        let (service, transport) = service { request, page in
            #expect(podQuery(request)["continue"] == (page == 1 ? nil : "next"))
            return try podMetadataPage(
                page == 1
                    ? [("a", "uid-a", "2026-10-01T00:00:00Z")]
                    : [("b", "uid-b", "2026-10-02T00:00:00Z")],
                cursor: page == 1 ? "next" : ""
            )
        }
        let pods = try await service.pods(
            context: try runtimeContext(), namespace: "team", selector: try LabelSelector(["app": "web"])
        )
        #expect(pods.map(\.name) == ["b", "a"])
        #expect(await transport.requests.count == 2)
    }

    /// A tab that silently tailed the first page would claim to follow a workload while missing most
    /// of it, so an endless or repeating cursor fails instead of truncating.
    @Test func anEndlessOrRepeatingCursorFailsRatherThanTruncating() async throws {
        let (endless, transport) = service { _, page in
            try podMetadataPage([("p\(page)", "uid-\(page)", nil)], cursor: "cursor-\(page)")
        }
        await #expect(throws: DeploymentPodFailure.tooManyPages) {
            try await endless.pods(
                context: try runtimeContext(), namespace: "team", selector: try LabelSelector(["app": "web"])
            )
        }
        #expect(await transport.requests.count == DeploymentPodService.pageLimit)

        let (repeating, _) = service { _, _ in try podMetadataPage([("p", "uid-p", nil)], cursor: "same") }
        await #expect(throws: DeploymentPodFailure.malformed) {
            try await repeating.pods(
                context: try runtimeContext(), namespace: "team", selector: try LabelSelector(["app": "web"])
            )
        }
    }

    /// The printed STATUS cell is display text, not a container's state, so nothing reads it: a
    /// Pending pod is returned and its own stream reports that it has no logs yet.
    @Test func rowsThatCannotBeAddressedAreSkippedAndPrintedCellsAreNeverRead() async throws {
        let (service, _) = service { _, _ in
            Data("""
            {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"1","continue":""},
             "columnDefinitions":[{"name":"Name","type":"string"}],
             "rows":[
              {"cells":["nameless"],"object":{"metadata":{"uid":"uid-x","namespace":"team"}}},
              {"cells":["uidless"],"object":{"metadata":{"name":"uidless","namespace":"team"}}},
              {"cells":["elsewhere"],"object":{"metadata":{"uid":"uid-e","name":"elsewhere","namespace":"other"}}},
              {"cells":["pending"],"object":{"metadata":{"uid":"uid-p","name":"pending","namespace":"team"}}},
              {"cells":["twice"],"object":{"metadata":{"uid":"uid-p","name":"twice","namespace":"team"}}}
             ]}
            """.utf8)
        }
        let pods = try await service.pods(
            context: try runtimeContext(), namespace: "team", selector: try LabelSelector(["app": "web"])
        )
        #expect(pods.map(\.name) == ["pending"])
    }

    @Test func anEmptyResultIsAnEmptySetRatherThanAFailure() async throws {
        let (service, _) = service { _, _ in try podMetadataPage([]) }
        let pods = try await service.pods(
            context: try runtimeContext(), namespace: "team", selector: try LabelSelector(["app": "web"])
        )
        #expect(pods.isEmpty)
    }

    @Test func anInvalidNamespaceNeverReachesTheNetwork() async throws {
        let (service, transport) = service { _, _ in try podMetadataPage([]) }
        await #expect(throws: APIError.invalidRequest) {
            try await service.pods(
                context: try runtimeContext(), namespace: "Bad", selector: try LabelSelector(["app": "web"])
            )
        }
        #expect(await transport.requests.isEmpty)
    }
}

/// Why the log session's configuration is what it is. URLSession allows 6 connections per host by
/// default, so over HTTP/1.1 the seventh of a deployment's pod streams would queue behind the first
/// six and the tab would claim to follow pods that were idle. Rather than rely on the apiserver
/// serving HTTP/2 — where these are multiplexed streams and the limit does not bite — the `.logs`
/// session raises the limit, so the behaviour does not depend on the protocol in play.
@Suite struct LogStreamConcurrencyTests {
    @Test func theLogSessionAllowsAsManyConnectionsAsItMayOpenStreams() {
        let logs = URLSessionFactory.configuration(for: .logs)
        #expect(logs.httpMaximumConnectionsPerHost == TransportPolicy.maximumConcurrentLogStreams)
        #expect(TransportPolicy.maximumConcurrentLogStreams == 50)
    }

    /// Only the log session. A watch is one stream, and raising the limit elsewhere would let an
    /// unrelated burst of requests open fifty connections to one apiserver.
    @Test func everyOtherPurposeKeepsThePlatformDefault() {
        for purpose in TransportPurpose.allCases where purpose != .logs {
            #expect(URLSessionFactory.configuration(for: purpose).httpMaximumConnectionsPerHost == 6)
        }
    }
}
