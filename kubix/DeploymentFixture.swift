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

    func deployments(_ request: APIRequest) throws -> Data {
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
