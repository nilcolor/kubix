import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

func deploymentDetailsData(
    uid: String = "deploy-uid", name: String = "web", namespace: String = "team",
    selector: [String: String]? = ["app": "web"], expressions: [[String: Any]]? = nil,
    containers: [String] = ["server"], initContainers: [[String: Any]]? = [["name": "migrate"]],
    annotation: String? = "server", apiVersion: String = "apps/v1", kind: String = "Deployment"
) throws -> Data {
    var template: [String: Any] = [
        "spec": ["containers": containers.map { ["name": $0] }] as [String: Any],
    ]
    if var spec = template["spec"] as? [String: Any], let initContainers {
        spec["initContainers"] = initContainers
        template["spec"] = spec
    }
    if let annotation {
        template["metadata"] = ["annotations": ["kubectl.kubernetes.io/default-container": annotation]]
    }
    var selectorObject: [String: Any] = [:]
    if let selector { selectorObject["matchLabels"] = selector }
    if let expressions { selectorObject["matchExpressions"] = expressions }
    return try JSONSerialization.data(withJSONObject: [
        "apiVersion": apiVersion, "kind": kind,
        "metadata": ["uid": uid, "name": name, "namespace": namespace],
        "spec": ["selector": selectorObject, "template": template] as [String: Any],
    ])
}

@Suite struct DeploymentDetailsServiceTests {
    private func service(_ body: @escaping @Sendable () throws -> Data) async throws -> (DeploymentDetailsService, ScriptedTransportSession) {
        let session = ScriptedTransportSession { _, _ in HTTPDataResponse(statusCode: 200, body: try body()) }
        let transport = try await testTransport(session: session, credentials: TransportCredentials())
        return (DeploymentDetailsService { _ in transport }, session)
    }

    @Test func aFreshPlainJSONGETAddressesTheAppsGroupAndRetainsOnlyWhatLogsNeed() async throws {
        let context = try transportConfiguration().resolve()
        let (service, session) = try await service { try deploymentDetailsData() }
        let details = try await service.details(context: context, namespace: "team", name: "web", uid: "deploy-uid")
        #expect(details.selector == ["app": "web"])
        #expect(details.defaultContainer == "server")
        #expect(details.containers.map(\.name) == ["server", "migrate"])
        #expect(details.containers.map(\.kind) == [.regular, .initContainer])
        // A template has no single state across replicas, so none is claimed.
        #expect(details.containers.allSatisfy { $0.state == .declared })
        let request = try #require(await session.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://synthetic.invalid/apis/apps/v1/namespaces/team/deployments/web")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    /// A native sidecar keeps running alongside the regular containers, so it is worth naming in the
    /// menu — and the template is the only place a deployment says so.
    @Test func aNativeSidecarIsRecognisedFromTheTemplate() async throws {
        let context = try transportConfiguration().resolve()
        let (service, _) = try await service {
            try deploymentDetailsData(initContainers: [["name": "proxy", "restartPolicy": "Always"], ["name": "migrate"]])
        }
        let details = try await service.details(context: context, namespace: "team", name: "web", uid: "deploy-uid")
        #expect(details.containers.map(\.isSidecar) == [false, true, false])
    }

    /// A selector this cannot serialize exactly must stop the request rather than be approximated:
    /// the wrong selector tails another workload's pods and looks like it worked.
    @Test func aSetBasedSelectorIsRefusedRatherThanApproximated() async throws {
        let context = try transportConfiguration().resolve()
        let (service, _) = try await service {
            try deploymentDetailsData(expressions: [["key": "tier", "operator": "In", "values": ["a"]]])
        }
        await #expect(throws: DeploymentDetailsError.setBasedSelector) {
            try await service.details(context: context, namespace: "team", name: "web", uid: "deploy-uid")
        }
    }

    /// An empty selector would match every pod in the namespace, which is never what was asked for.
    @Test func anEmptySelectorIsRefused() async throws {
        let context = try transportConfiguration().resolve()
        for body in [try deploymentDetailsData(selector: nil), try deploymentDetailsData(selector: [:])] {
            let (service, _) = try await service { body }
            await #expect(throws: DeploymentDetailsError.emptySelector) {
                try await service.details(context: context, namespace: "team", name: "web", uid: "deploy-uid")
            }
        }
    }

    @Test func aBodyThatIsNotAnAppsV1DeploymentIsMalformed() async throws {
        let context = try transportConfiguration().resolve()
        for body in [
            try deploymentDetailsData(apiVersion: "v1"),
            try deploymentDetailsData(kind: "ReplicaSet"),
            try deploymentDetailsData(uid: ""),
            try deploymentDetailsData(containers: ["server", "server"]),
            Data("{}".utf8),
        ] {
            let (service, _) = try await service { body }
            await #expect(throws: DeploymentDetailsError.malformed) {
                try await service.details(context: context, namespace: "team", name: "web", uid: "deploy-uid")
            }
        }
    }

    /// Name-addressed endpoints cannot be given a UID precondition, so the fetched identity is what
    /// proves the row the user clicked is the object that answered.
    @Test func aChangedIdentityIsReplacementOrMismatchRatherThanAccepted() async throws {
        let context = try transportConfiguration().resolve()
        let (replaced, _) = try await service { try deploymentDetailsData(uid: "other-uid") }
        await #expect(throws: DeploymentDetailsError.replaced) {
            try await replaced.details(context: context, namespace: "team", name: "web", uid: "deploy-uid")
        }
        let (mismatched, _) = try await service { try deploymentDetailsData(namespace: "other") }
        await #expect(throws: DeploymentDetailsError.identityMismatch) {
            try await mismatched.details(context: context, namespace: "team", name: "web", uid: "deploy-uid")
        }
    }

    @Test func aTemplateWithNoContainersCannotServeLogs() async throws {
        let context = try transportConfiguration().resolve()
        let (service, _) = try await service { try deploymentDetailsData(containers: [], initContainers: nil) }
        await #expect(throws: DeploymentDetailsError.noContainers) {
            try await service.details(context: context, namespace: "team", name: "web", uid: "deploy-uid")
        }
    }

    @Test func anInvalidTargetNeverReachesTheNetwork() async throws {
        let context = try transportConfiguration().resolve()
        let session = ScriptedTransportSession { _, _ in HTTPDataResponse(statusCode: 200, body: try deploymentDetailsData()) }
        let transport = try await testTransport(session: session, credentials: TransportCredentials())
        let service = DeploymentDetailsService { _ in transport }
        for (namespace, name, uid) in [("team", "", "u"), ("team", "..", "u"), ("team", "a/b", "u"), ("team", "web", ""), ("Bad", "web", "u")] {
            await #expect(throws: APIError.invalidRequest) {
                try await service.details(context: context, namespace: namespace, name: name, uid: uid)
            }
        }
        #expect(await session.requests.isEmpty)
    }
}
