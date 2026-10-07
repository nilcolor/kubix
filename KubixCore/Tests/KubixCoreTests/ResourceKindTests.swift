import Foundation
import KubixCore
import Testing

/// What differs between the kinds one watch serves. The paths are what a request is built from, so a
/// wrong one reaches the wrong resource — or, for deployments, a URL under `api/v1` that does not
/// exist at all.
@Suite struct ResourceKindTests {
    @Test func eachKindNamesItsOwnAPIGroup() {
        #expect(ResourceKind.pods.apiPath == ["api", "v1"])
        #expect(ResourceKind.deployments.apiPath == ["apis", "apps", "v1"])
        #expect(ResourceKind.allCases.map(\.resource) == ["pods", "deployments"])
    }

    @Test func requestsAreBuiltFromTheKindAlone() {
        let pods = APIRequest(resource: ResourceKind.pods.resource, namespace: "team", apiPath: ResourceKind.pods.apiPath, table: true)
        #expect(pods.path == ["api", "v1", "namespaces", "team", "pods"])
        let deployments = APIRequest(
            resource: ResourceKind.deployments.resource, namespace: "team",
            apiPath: ResourceKind.deployments.apiPath, table: true
        )
        #expect(deployments.path == ["apis", "apps", "v1", "namespaces", "team", "deployments"])
        #expect(deployments.accept == APIRequest.tableAccept)
    }

    /// Both capabilities are pod-only, and for unrelated reasons: a deployment has no single
    /// container to exec into, and `metrics.k8s.io` has no deployment resource to read.
    @Test func onlyPodsOfferShellsAndUsageColumns() {
        #expect(ResourceKind.pods.supportsShell)
        #expect(ResourceKind.pods.supportsUsageColumns)
        #expect(!ResourceKind.deployments.supportsShell)
        #expect(!ResourceKind.deployments.supportsUsageColumns)
    }

    @Test func countsReadAsSentencesInBothKinds() {
        #expect(ResourceKind.pods.noun == ("pod", "pods"))
        #expect(ResourceKind.deployments.noun == ("deployment", "deployments"))
        #expect(ResourceKind.allCases.map(\.title) == ["Pods", "Deployments"])
    }
}

@Suite struct SidebarSelectionKindTests {
    @Test func aSelectionCarriesTheKindItLists() {
        #expect(SidebarSelection.cluster("first").kind == nil)
        #expect(SidebarSelection.list("first", .deployments).kind == .deployments)
        #expect(SidebarSelection.list("first", .deployments).clusterName == "first")
        // Two kinds on one cluster are two selections, or the sidebar could not tell them apart.
        #expect(SidebarSelection.list("first", .pods) != SidebarSelection.list("first", .deployments))
    }

    /// A list of either kind is only as alive as its cluster's connection.
    @Test func everyKindIsDemotedOnAClusterThatIsNotConnected() throws {
        let clusters = [
            ClusterStatus(context: try appContext(), state: .connected),
            ClusterStatus(context: try appContext("second"), state: .connecting),
        ]
        #expect(SidebarSelection.reconcile(.list("first", .deployments), clusters: clusters, preferred: nil)
            == .list("first", .deployments))
        #expect(SidebarSelection.reconcile(.list("second", .deployments), clusters: clusters, preferred: nil)
            == .cluster("second"))
    }
}
