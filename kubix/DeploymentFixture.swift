#if DEBUG
import Foundation
import KubixCore

/// The deployments half of the native smoke's transport: a Table with the kubectl printer's own
/// columns, so the pane is driven by a schema the app has never seen rather than the pod one under
/// another name. Creation times are relative to the first serve and the printed ages are
/// deliberately wrong, so a computed Age cell cannot be mistaken for the server's.
extension PodFixtureTransport {
    struct DeploymentFixtureRow {
        let name: String
        let ready: String
        let age: TimeInterval
        let printed: String
    }

    /// Three deployments with distinct readiness, one name long enough to need the Name column's
    /// fit, and printed ages no computed cell could produce.
    static let deploymentRows = [
        DeploymentFixtureRow(name: "checkout-api-gateway-deployment", ready: "3/3", age: -7_200, printed: "6d"),
        DeploymentFixtureRow(name: "ledger", ready: "1/3", age: -90, printed: "9d"),
        DeploymentFixtureRow(name: "notifications", ready: "0/1", age: -600, printed: "12d"),
    ]

    /// The pods the `ledger` deployment owns, and the ones a neighbouring deployment owns while
    /// carrying the same `app` label — the shape that made a selector-only lookup tail three
    /// workloads and call it one.
    static let deploymentPodNames = ["ledger-7d9f-a", "ledger-7d9f-b", "ledger-6c2e-c"]
    static let neighbourPodNames = ["ledger-dj-slow-1a2b-a", "ledger-dj-slow-1a2b-b"]
    static let ledgerReplicaSet = "rs-ledger-7d9f"
    static let neighbourReplicaSet = "rs-ledger-dj-slow-1a2b"

    func deployments(_ request: APIRequest) throws -> Data {
        if request.path.count == 7, request.accept == "application/json" {
            return try Self.deployment(named: request.path[6], namespace: request.path[4])
        }
        if request.path.count == 6, request.path[5] == "replicasets" { return Self.replicaSets(namespace: request.path[4]) }
        guard request.path.count == 6, request.path[3] == "namespaces", request.path[5] == "deployments",
              request.accept == APIRequest.tableAccept else { throw APIError.invalidRequest }
        let namespace = request.path[4]
        if namespace == "forbidden" { throw APIError.http(code: 403, resource: "deployments") }
        let base = deploymentBase ?? Date()
        deploymentBase = base
        let rows = (namespace == "empty" ? [] : Self.deploymentRows)
            .map { Self.row($0, namespace: namespace, base: base) }
            .joined(separator: ",")
        return Data("""
        {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"deploy-rv","continue":""},
         "columnDefinitions":[{"name":"Name","type":"string"},{"name":"Ready","type":"string"},
          {"name":"Up-to-date","type":"string"},{"name":"Available","type":"string"},{"name":"Age","type":"string"},
          {"name":"Selector","type":"string","priority":1}],
         "rows":[\(rows)]}
        """.utf8)
    }

    /// One deployment, as the aggregated log flow reads it: a selector to find its pods with, and
    /// two template containers so the flow has a menu to show.
    private static func deployment(named name: String, namespace: String) throws -> Data {
        guard deploymentRows.contains(where: { $0.name == name }) else { throw APIError.invalidRequest }
        return try JSONSerialization.data(withJSONObject: [
            "apiVersion": "apps/v1", "kind": "Deployment",
            "metadata": ["uid": "deploy-\(name)", "name": name, "namespace": namespace],
            "spec": [
                "selector": ["matchLabels": ["app": name]],
                "template": [
                    "metadata": ["annotations": ["kubectl.kubernetes.io/default-container": "server"]],
                    "spec": ["containers": [["name": "server"], ["name": "proxy"]]],
                ],
            ] as [String: Any],
        ])
    }

    /// Two ReplicaSets matching the shared label, owned by two different deployments. Only one is
    /// the one whose logs were asked for.
    static func replicaSets(namespace: String) -> Data {
        let rows = [(ledgerReplicaSet, "deploy-ledger"), (neighbourReplicaSet, "deploy-ledger-dj-slow")]
            .map { set, owner in
                let meta = [
                    #""uid":"\#(set)""#, #""name":"\#(set)""#, #""namespace":"\#(namespace)""#,
                    owned(by: owner, kind: "Deployment", name: set),
                ].joined(separator: ",")
                return #"{"cells":["\#(set)","1","1","1","9d"],"object":{"metadata":{\#(meta)}}}"#
            }.joined(separator: ",")
        return Data(#"""
        {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"rs","continue":""},
         "columnDefinitions":[{"name":"Name","type":"string"},{"name":"Desired","type":"string"},
          {"name":"Current","type":"string"},{"name":"Ready","type":"string"},{"name":"Age","type":"string"}],
         "rows":[\#(rows)]}
        """#.utf8)
    }

    /// Everything the shared label selects: the deployment's own pods, a neighbouring deployment's,
    /// and a bare pod owned by nothing. Dated oldest-first on purpose, so the order the tab tails in
    /// is one it sorted into rather than the one it was handed.
    static func selectedPods(namespace: String, base: Date) -> Data {
        let owned = deploymentPodNames.enumerated().map { index, name in
            let created = timestamp(base.addingTimeInterval(-600 + Double(index) * 60))
            return pod(name, namespace: namespace, created: created, replicaSet: ledgerReplicaSet)
        }
        let neighbours = neighbourPodNames.map { name in
            pod(name, namespace: namespace, created: nil, replicaSet: neighbourReplicaSet)
        }
        let bare = [pod("ledger-bare", namespace: namespace, created: nil, replicaSet: nil)]
        let rows = (owned + neighbours + bare).joined(separator: ",")
        return Data(#"""
        {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"sel","continue":""},
         "columnDefinitions":[{"name":"Name","type":"string"},{"name":"Status","type":"string"},
          {"name":"Ready","type":"string"},{"name":"Restarts","type":"string"},{"name":"Age","type":"string"}],
         "rows":[\#(rows)]}
        """#.utf8)
    }

    private static func owned(by uid: String, kind: String, name: String) -> String {
        #""ownerReferences":[{"uid":"\#(uid)","kind":"\#(kind)","name":"\#(name)","controller":true}]"#
    }

    private static func pod(_ name: String, namespace: String, created: String?, replicaSet: String?) -> String {
        var meta = [#""uid":"pod-\#(name)""#, #""name":"\#(name)""#, #""namespace":"\#(namespace)""#]
        if let created { meta.append(#""creationTimestamp":"\#(created)""#) }
        if let replicaSet { meta.append(owned(by: replicaSet, kind: "ReplicaSet", name: replicaSet)) }
        return #"{"cells":["\#(name)","Running","1/1","0","10m"],"object":{"metadata":{\#(meta.joined(separator: ","))}}}"#
    }

    private static func row(_ row: DeploymentFixtureRow, namespace: String, base: Date) -> String {
        let cells = [row.name, row.ready, "3", "3", row.printed, "app=\(row.name)"]
            .map { #""\#($0)""# }.joined(separator: ",")
        let metadata = [
            #""uid":"deploy-\#(row.name)""#, #""name":"\#(row.name)""#, #""namespace":"\#(namespace)""#,
            #""resourceVersion":"d1""#, #""creationTimestamp":"\#(timestamp(base.addingTimeInterval(row.age)))""#,
        ].joined(separator: ",")
        return #"{"cells":[\#(cells)],"object":{"metadata":{\#(metadata)}}}"#
    }
}
#endif
