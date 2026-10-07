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

    /// The pods of every fixture deployment, which the selector's list returns and whose logs
    /// stream. Three, so an aggregated tab has more than one source to interleave and label.
    static let deploymentPodNames = ["ledger-7d9f-a", "ledger-7d9f-b", "ledger-6c2e-c"]

    func deployments(_ request: APIRequest) throws -> Data {
        if request.path.count == 7, request.accept == "application/json" {
            return try Self.deployment(named: request.path[6], namespace: request.path[4])
        }
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

    /// The selector's pods, as a metadata Table. Dated oldest-first on purpose, so the order the tab
    /// tails in is one it sorted into rather than the one it was handed.
    static func selectedPods(namespace: String, base: Date) -> Data {
        let rows = deploymentPodNames.enumerated().map { index, name in
            let created = timestamp(base.addingTimeInterval(-600 + Double(index) * 60))
            return #"{"cells":["\#(name)","Running","1/1","0","10m"],"object":{"metadata":{"uid":"pod-\#(name)","name":"\#(name)","namespace":"\#(namespace)","creationTimestamp":"\#(created)"}}}"#
        }.joined(separator: ",")
        return Data(#"""
        {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"sel","continue":""},
         "columnDefinitions":[{"name":"Name","type":"string"},{"name":"Status","type":"string"},
          {"name":"Ready","type":"string"},{"name":"Restarts","type":"string"},{"name":"Age","type":"string"}],
         "rows":[\#(rows)]}
        """#.utf8)
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
