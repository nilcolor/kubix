import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

/// The same watch, asked for a different kind. These assert the two things kind-parameterization can
/// get wrong — the URL it builds and the kind it labels its updates with — and then that every
/// snapshot guarantee the pod list has still holds for a resource in another API group.
@Suite @MainActor struct DeploymentWatchTests {
    @Test func listAndWatchAddressTheAppsGroupAndLabelTheirUpdates() async throws {
        let transport = WatchTestTransport { request, page in
            #expect(request.path == ["apis", "apps", "v1", "namespaces", "team", "deployments"])
            #expect(request.accept == APIRequest.tableAccept && request.managesCredentialRefresh)
            #expect(podQuery(request) == (page == 1
                ? ["limit": "500", "includeObject": "Metadata"]
                : ["limit": "500", "includeObject": "Metadata", "continue": "cursor-2"]))
            return try deploymentPage(ids: page == 1 ? [0, 1] : [2], cursor: page == 1 ? "cursor-2" : "")
        }
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start(.deployments)
        try await watchEventually { owner.store.connection == .live }
        #expect(owner.store.rows.map(\.id) == ["deploy-uid-0", "deploy-uid-1", "deploy-uid-2"])
        #expect(owner.store.columns?.map(\.name) == ["Name", "Ready", "Up-to-date", "Available", "Age"])
        #expect(owner.store.listKind == .deployments)
        #expect(owner.capture.values.allSatisfy { $0.kind == .deployments })
        let stream = try #require(await transport.streams.first)
        #expect(stream.path == ["apis", "apps", "v1", "namespaces", "team", "deployments"])
        #expect(podQuery(stream) == [
            "watch": "true", "allowWatchBookmarks": "true", "timeoutSeconds": "300",
            "includeObject": "Metadata", "resourceVersion": "opaque-list",
        ])
        await owner.stop()
    }

    /// A deployment row carries its printed cells and its own identity, and the creation time the
    /// synthetic Age column needs — none of which the pod path can vouch for on another kind.
    @Test func rowsCarryPrintedCellsAndTheIdentityTheyWillBeSortedBy() async throws {
        let transport = WatchTestTransport { _, _ in try deploymentPage(ids: [7]) }
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start(.deployments)
        try await watchEventually { owner.store.connection == .live }
        let row = try #require(owner.store.rows.first)
        #expect(row.cells.map(\.displayText) == ["deploy-7", "3/3", "3", "3", "6d"])
        #expect(row.metadata.name == "deploy-7" && row.metadata.namespace == "team")
        #expect(row.metadata.creationTimestamp == RFC3339.date(from: "2026-10-01T00:00:00Z"))
        await owner.stop()
    }

    @Test func aHeaderlessDeploymentEventKeepsTheSchemaAndAppliesTheRow() async throws {
        let stream = MemoryByteStream([try deploymentEvent("ADDED", id: 5)])
        let transport = WatchTestTransport(
            data: { _, _ in try deploymentPage(ids: [0]) }, stream: { _, _ in stream }
        )
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start(.deployments)
        try await watchEventually { owner.store.rows.count == 2 }
        #expect(owner.store.rows.map(\.id) == ["deploy-uid-0", "deploy-uid-5"])
        #expect(owner.store.columns?.count == 5)
        await owner.stop()
    }

    /// 410 expires a deployments snapshot exactly as it expires a pod one: nothing is carried over
    /// from the old resource version, including a continuation that was already in flight.
    @Test func anExpiredDeploymentsSnapshotIsRebuiltFromPageOne() async throws {
        let transport = WatchTestTransport { request, call in
            switch call {
            case 1: return try deploymentPage(ids: [91], version: "old", cursor: "expired")
            case 2:
                #expect(podQuery(request)["continue"] == "expired")
                throw APIError.http(code: 410, resource: "deployments")
            default:
                #expect(podQuery(request)["continue"] == nil)
                return try deploymentPage(ids: [1], version: "fresh", cursor: "")
            }
        }
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start(.deployments)
        try await watchEventually { owner.store.connection == .live }
        #expect(owner.store.rows.map(\.id) == ["deploy-uid-1"])
        await owner.stop()
    }

    /// The watch is the resource's, not the kind's in general: a page whose rows belong to another
    /// namespace is still rejected, and a schema that changes mid-snapshot still fails the install.
    @Test func snapshotValidationStillRejectsMismatchedPages() async throws {
        let wrongNamespace = WatchTestTransport { _, _ in try deploymentPage(ids: [0], namespace: "other") }
        let first = try WatchTestOwner(transport: wrongNamespace)
        defer { first.actions.shutdown() }
        first.start(.deployments)
        try await watchEventually { first.store.connection == .failed(.snapshot(.invalidRow)) }
        await first.stop()

        let changingSchema = WatchTestTransport { _, page in
            try deploymentPage(
                ids: [page], cursor: page == 1 ? "cursor-2" : "",
                columns: page == 1 ? deploymentColumns() : deploymentColumns(wide: true)
            )
        }
        let second = try WatchTestOwner(transport: changingSchema)
        defer { second.actions.shutdown() }
        second.start(.deployments)
        try await watchEventually { second.store.connection == .failed(.snapshot(.inconsistentSchema)) }
        await second.stop()
    }
}
