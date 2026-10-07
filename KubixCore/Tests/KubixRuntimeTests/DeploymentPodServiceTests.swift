import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

private func podMetadataPage(
    _ pods: [(name: String, uid: String, created: String?)], cursor: String = "", namespace: String = "team",
    owner: String? = "rs-0"
) throws -> Data {
    let rows = pods.map { pod in
        let created = pod.created.map { #","creationTimestamp":"\#($0)""# } ?? ""
        let owned = owner.map { #","ownerReferences":[{"uid":"\#($0)","kind":"ReplicaSet","name":"\#($0)","controller":true}]"# } ?? ""
        return #"{"cells":["\#(pod.name)","Running","1/1","0","5m"],"object":{"metadata":{"uid":"\#(pod.uid)","name":"\#(pod.name)","namespace":"\#(namespace)"\#(created)\#(owned)}}}"#
    }.joined(separator: ",")
    return Data("""
    {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"1","continue":"\(cursor)"},
     "columnDefinitions":[{"name":"Name","type":"string"},{"name":"Status","type":"string"},
      {"name":"Ready","type":"string"},{"name":"Restarts","type":"string"},{"name":"Age","type":"string"}],
     "rows":[\(rows)]}
    """.utf8)
}

/// One ReplicaSet owned by the deployment, which is the first of the service's two steps.
private func replicaSetPage(
    _ sets: [(name: String, uid: String)] = [("rs", "rs-0")], cursor: String = "",
    namespace: String = "team", owner: String? = "deploy-uid"
) -> Data {
    let rows = sets.map { set in
        let owned = owner.map { #","ownerReferences":[{"uid":"\#($0)","kind":"Deployment","name":"web","controller":true}]"# } ?? ""
        return #"{"cells":["\#(set.name)","1","1","1","5m"],"object":{"metadata":{"uid":"\#(set.uid)","name":"\#(set.name)","namespace":"\#(namespace)"\#(owned)}}}"#
    }.joined(separator: ",")
    return Data("""
    {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"1","continue":"\(cursor)"},
     "columnDefinitions":[{"name":"Name","type":"string"},{"name":"Desired","type":"string"},
      {"name":"Current","type":"string"},{"name":"Ready","type":"string"},{"name":"Age","type":"string"}],
     "rows":[\(rows)]}
    """.utf8)
}

@Suite struct DeploymentPodServiceTests {
    /// Answers the ReplicaSet step with one owned set, and hands the pod step to `body`.
    private func service(
        _ body: @escaping @Sendable (APIRequest, Int) async throws -> Data
    ) -> (DeploymentPodService, WatchTestTransport) {
        let transport = WatchTestTransport(data: { request, call in
            guard request.path.contains("pods") else { return replicaSetPage() }
            return try await body(request, call - 1)
        })
        return (DeploymentPodService { _ in transport }, transport)
    }

    /// Two selector-scoped metadata Tables: the deployment's ReplicaSets, then the pods those own.
    @Test func ownershipIsResolvedThroughTheReplicaSetsTheDeploymentOwns() async throws {
        let selector = try LabelSelector(["app": "web", "pod-template-hash": "7d9f"])
        let (service, transport) = service { _, _ in
            try podMetadataPage([("web-7d9f-a", "uid-a", "2026-10-01T00:00:00Z")])
        }
        let pods = try await service.pods(
            context: try runtimeContext(), namespace: "team", owner: "deploy-uid", selector: selector
        )
        #expect(pods.map(\.name) == ["web-7d9f-a"])
        #expect(pods.map(\.uid) == ["uid-a"])
        #expect(pods.first?.created == RFC3339.date(from: "2026-10-01T00:00:00Z"))
        let requests = await transport.requests
        #expect(requests.map(\.path) == [
            ["apis", "apps", "v1", "namespaces", "team", "replicasets"],
            ["api", "v1", "namespaces", "team", "pods"],
        ])
        #expect(requests.allSatisfy { $0.accept == APIRequest.tableAccept })
        // The selector still scopes both, because fetching a whole namespace to filter it would be
        // the expensive way to reach the same answer.
        #expect(requests.allSatisfy {
            podQuery($0) == [
                "limit": "500", "includeObject": "Metadata", "labelSelector": "app=web,pod-template-hash=7d9f",
            ]
        })
    }

    /// The defect this replaced selector matching for. A chart that gives two deployments the same
    /// `app` label leaves the first one's selector matching the second one's pods, so selecting by
    /// labels tailed three workloads and called it one.
    @Test func podsOfAnotherDeploymentMatchingTheSameLabelsAreNotTailed() async throws {
        let transport = WatchTestTransport(data: { request, _ in
            guard request.path.contains("pods") else {
                // Both deployments' ReplicaSets carry the shared label; only one is ours.
                return replicaSetPage([("core", "rs-core")], owner: "deploy-core")
            }
            return try podMetadataPage([("core-a", "uid-a", nil), ("core-b", "uid-b", nil)], owner: "rs-core")
        })
        let service = DeploymentPodService { _ in transport }
        let pods = try await service.pods(
            context: try runtimeContext(), namespace: "team", owner: "deploy-core",
            selector: try LabelSelector(["app": "synthetic-container"])
        )
        #expect(pods.map(\.name) == ["core-a", "core-b"])

        // The same namespace, with the other workload's pods mixed into the same selector result.
        let mixed = WatchTestTransport(data: { request, _ in
            guard request.path.contains("pods") else {
                return replicaSetPage([("core", "rs-core")], owner: "deploy-core")
            }
            func owned(_ name: String, _ uid: String, by set: String?) -> String {
                let owner = set.map {
                    #","ownerReferences":[{"uid":"\#($0)","kind":"ReplicaSet","name":"\#($0)","controller":true}]"#
                } ?? ""
                return #"{"cells":["\#(name)"],"object":{"metadata":{"uid":"\#(uid)","name":"\#(name)","namespace":"team"\#(owner)}}}"#
            }
            let ours = owned("core-a", "uid-a", by: "rs-core")
            let theirs = owned("slow-a", "uid-s", by: "rs-slow")
            let orphan = owned("bare", "uid-o", by: nil)
            return Data("""
            {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"1","continue":""},
             "columnDefinitions":[{"name":"Name","type":"string"}],"rows":[\(ours),\(theirs),\(orphan)]}
            """.utf8)
        })
        let narrowed = try await DeploymentPodService { _ in mixed }.pods(
            context: try runtimeContext(), namespace: "team", owner: "deploy-core",
            selector: try LabelSelector(["app": "synthetic-container"])
        )
        // The other deployment's pod and the bare pod both match the labels and neither is ours.
        #expect(narrowed.map(\.name) == ["core-a"])
    }

    /// A deployment whose ReplicaSets are not among the selector's matches owns none of those pods,
    /// however well they match.
    @Test func noOwnedReplicaSetMeansNoPodsRatherThanEveryMatch() async throws {
        let transport = WatchTestTransport(data: { request, _ in
            guard request.path.contains("pods") else { return replicaSetPage(owner: "another-deployment") }
            Issue.record("The pods must not be fetched once nothing owns them.")
            return try podMetadataPage([("web", "uid-a", nil)])
        })
        let pods = try await DeploymentPodService { _ in transport }.pods(
            context: try runtimeContext(), namespace: "team", owner: "deploy-uid",
            selector: try LabelSelector(["app": "web"])
        )
        #expect(pods.isEmpty)
        #expect(await transport.requests.count == 1)
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
            context: try runtimeContext(), namespace: "team", owner: "deploy-uid",
                selector: try LabelSelector(["app": "web"])
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
            context: try runtimeContext(), namespace: "team", owner: "deploy-uid",
                selector: try LabelSelector(["app": "web"])
        )
        #expect(pods.map(\.name) == ["b", "a"])
        // One ReplicaSet request, then both pod pages.
        #expect(await transport.requests.count == 3)
    }

    /// A tab that silently tailed the first page would claim to follow a workload while missing most
    /// of it, so an endless or repeating cursor fails instead of truncating.
    @Test func anEndlessOrRepeatingCursorFailsRatherThanTruncating() async throws {
        let (endless, transport) = service { _, page in
            try podMetadataPage([("p\(page)", "uid-\(page)", nil)], cursor: "cursor-\(page)")
        }
        await #expect(throws: DeploymentPodFailure.tooManyPages) {
            try await endless.pods(
                context: try runtimeContext(), namespace: "team", owner: "deploy-uid",
                selector: try LabelSelector(["app": "web"])
            )
        }
        #expect(await transport.requests.count == DeploymentPodService.pageLimit + 1)

        let (repeating, _) = service { _, _ in try podMetadataPage([("p", "uid-p", nil)], cursor: "same") }
        await #expect(throws: DeploymentPodFailure.malformed) {
            try await repeating.pods(
                context: try runtimeContext(), namespace: "team", owner: "deploy-uid",
                selector: try LabelSelector(["app": "web"])
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
              {"cells":["nameless"],"object":{"metadata":{"uid":"uid-x","namespace":"team","ownerReferences":[{"uid":"rs-0","kind":"ReplicaSet","name":"rs","controller":true}]}}},
              {"cells":["uidless"],"object":{"metadata":{"name":"uidless","namespace":"team","ownerReferences":[{"uid":"rs-0","kind":"ReplicaSet","name":"rs","controller":true}]}}},
              {"cells":["elsewhere"],"object":{"metadata":{"uid":"uid-e","name":"elsewhere","namespace":"other","ownerReferences":[{"uid":"rs-0","kind":"ReplicaSet","name":"rs","controller":true}]}}},
              {"cells":["pending"],"object":{"metadata":{"uid":"uid-p","name":"pending","namespace":"team","ownerReferences":[{"uid":"rs-0","kind":"ReplicaSet","name":"rs","controller":true}]}}},
              {"cells":["twice"],"object":{"metadata":{"uid":"uid-p","name":"twice","namespace":"team","ownerReferences":[{"uid":"rs-0","kind":"ReplicaSet","name":"rs","controller":true}]}}}
             ]}
            """.utf8)
        }
        let pods = try await service.pods(
            context: try runtimeContext(), namespace: "team", owner: "deploy-uid",
                selector: try LabelSelector(["app": "web"])
        )
        #expect(pods.map(\.name) == ["pending"])
    }

    @Test func anEmptyResultIsAnEmptySetRatherThanAFailure() async throws {
        let (service, _) = service { _, _ in try podMetadataPage([]) }
        let pods = try await service.pods(
            context: try runtimeContext(), namespace: "team", owner: "deploy-uid",
                selector: try LabelSelector(["app": "web"])
        )
        #expect(pods.isEmpty)
    }

    @Test func anInvalidNamespaceNeverReachesTheNetwork() async throws {
        let (service, transport) = service { _, _ in try podMetadataPage([]) }
        await #expect(throws: APIError.invalidRequest) {
            try await service.pods(
                context: try runtimeContext(), namespace: "Bad", owner: "deploy-uid",
                selector: try LabelSelector(["app": "web"])
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
