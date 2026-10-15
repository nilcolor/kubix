#if DEBUG
import AppKit
import KubixCore
import KubixRuntime

/// Fixed, in-memory dependencies for the native smoke. No real config, credentials, browser or transport.
@MainActor final class PodBrowsingFixture {
    let store = AppStore()
    let transport = PodFixtureTransport()
    let authentication = PodFixtureAuth()
    let metrics = PodFixtureMetrics()
    let surfaces = PodFixtureSurfaces()
    let actions: AppActions

    init() {
        actions = AppActions(
            store: store, exec: PodFixtureExec(), authentication: authentication, surfaces: surfaces,
            configurations: PodFixtureConfiguration(), lists: WatchService(transports: { [transport] _ in transport }),
            podDetails: PodDetailsService(transports: { [transport] _ in transport }),
            deploymentDetails: DeploymentDetailsService(transports: { [transport] _ in transport }),
            deploymentPods: DeploymentPodService(transports: { [transport] _ in transport }),
            podDeleter: PodDeleteService(transports: { [transport] _ in transport }),
            logs: LogService(transports: { [transport] _ in transport }),
            probe: ClusterProbeService(transports: { [transport] _ in transport }),
            namespaces: NamespaceListService(transports: { [transport] _ in transport }),
            // Its own transport: a poll running under every stage would otherwise change the request
            // counts the other stages assert.
            metrics: PodMetricsService(transports: { [metrics] _ in metrics }),
            metricsInterval: .milliseconds(200)
        )
    }
}

private struct PodFixtureConfiguration: AppConfigurationLoading {
    func load() -> AppConfiguration {
        let config = Kubeconfig(
            currentContext: "synthetic-first",
            clusters: [
                .init(name: "safe", cluster: .init(server: "https://synthetic.invalid")),
                .init(name: "blocked", cluster: .init(server: "https://synthetic.invalid", proxyURL: "http://synthetic.invalid")),
            ],
            contexts: [
                .init(name: "synthetic-first", context: .init(cluster: "safe", user: "wrapper", namespace: "team")),
                .init(name: "synthetic-second", context: .init(cluster: "safe", user: "wrapper", namespace: "other")),
                .init(name: "synthetic-proxy", context: .init(cluster: "blocked", namespace: "never")),
                // A realistically long context name: the sidebar must truncate it, never widen its
                // content past the column and scroll sideways.
                .init(
                    name: "synthetic-very-long-provider-generated-context-name-us-east4-cluster-1",
                    context: .init(cluster: "safe", user: "wrapper", namespace: "team")
                ),
            ],
            users: [.init(name: "wrapper", user: .init(exec: .init(
                command: "/synthetic/configured-wrapper", apiVersion: "client.authentication.k8s.io/v1", interactiveMode: "Never"
            ))) ]
        )
        return AppConfiguration(configuration: config, settings: AuthSettings())
    }
}

actor PodFixtureTransport: Transport {
    private(set) var requests: [APIRequest] = []
    private(set) var streams: [PodFixtureStream] = []
    private(set) var logStreams: [PodFixtureStream] = []
    private(set) var logRequests: [APIRequest] = []
    private(set) var scaleRequests = 0
    private(set) var scaleWatchVersions: [String] = []
    private var scaleRelisted = false
    /// Fixed when the page is first served, not when the fixture starts: the usage stage runs last,
    /// and `zulu` must still be young enough to tick in seconds when it gets there. Fixed thereafter,
    /// so a relist describes the same pods with the same ages.
    private var timedBase: Date?

    /// Set before a Connect to make the next probe fail, for the driver's failure-then-Retry stage.
    var probeFailure: APIError?
    /// Set before a Connect to deny the namespace list, for the driver's typed-entry fallback stage.
    var namespaceFailure: APIError?
    private(set) var namespaceRequests = 0
    var deploymentBase: Date?

    func failNextProbe(_ error: APIError?) { probeFailure = error }
    func failNamespaceList(_ error: APIError?) { namespaceFailure = error }

    func data(for request: APIRequest) async throws -> Data {
        requests.append(request)
        if request.path == ["version"] {
            if let error = probeFailure {
                probeFailure = nil
                throw error
            }
            return Data(#"{"gitVersion":"v1.29.4-synthetic"}"#.utf8)
        }
        if request.path == ["api", "v1", "namespaces"] {
            namespaceRequests += 1
            if let error = namespaceFailure { throw error }
            return Self.namespaceTable()
        }
        if request.path.prefix(3) == ["apis", "apps", "v1"] { return try deployments(request) }
        if request.accept == "application/json" { return try Self.details(request) }
        return try await podTable(request)
    }

    private func podTable(_ request: APIRequest) async throws -> Data {
        // A selector-scoped list is a deployment's pods, not the namespace's.
        if request.query.contains(where: { $0.name == "labelSelector" }), request.path.count == 5 {
            let base = deploymentBase ?? Date()
            deploymentBase = base
            return Self.selectedPods(namespace: request.path[3], base: base)
        }
        if request.path == ["api", "v1", "namespaces", "scale", "pods"] { return try await scalePage(request) }
        if request.path == ["api", "v1", "namespaces", "timed", "pods"] {
            let base = timedBase ?? Date()
            timedBase = base
            return Self.timedPage(created: base)
        }
        guard request.path.count == 5, request.path.prefix(3) == ["api", "v1", "namespaces"],
              request.path.last == "pods", request.accept == APIRequest.tableAccept,
              ["team", "other", "known", "empty", "forbidden"].contains(request.path[3]) else { throw APIError.invalidRequest }
        let namespace = request.path[3]
        if namespace == "forbidden" { throw APIError.http(code: 403, resource: "pods") }
        let second = request.query.contains { $0.name == "continue" }
        if second { try await Task.sleep(for: .seconds(1)) }
        return Self.page(namespace: namespace, second: second, empty: namespace == "empty")
    }

    func stream(for request: APIRequest, purpose: TransportPurpose) throws -> any HTTPByteStream {
        if purpose == .logs {
            guard request.path.count == 7, request.path[3] == "team", request.path[4] == "pods",
                  ["alpha", "zulu"].contains(request.path[5]) || Self.deploymentPodNames.contains(request.path[5]),
                  request.path.last == "log",
                  request.accept == "application/json",
                  request.query.contains(where: { $0.name == "tailLines" }) else { throw APIError.invalidRequest }
            let stream = PodFixtureStream()
            logStreams.append(stream)
            logRequests.append(request)
            stream.yield(Data((0..<400).map { "synthetic fixture line \($0)\n" }.joined().utf8))
            return stream
        }
        if purpose == .watch, request.path.last == "deployments" {
            let stream = PodFixtureStream()
            streams.append(stream)
            return stream
        }
        guard purpose == .watch, request.path.last == "pods" else { throw APIError.invalidRequest }
        if request.path[3] == "scale" {
            scaleWatchVersions.append(request.query.first { $0.name == "resourceVersion" }?.value ?? "")
        }
        let stream = PodFixtureStream()
        streams.append(stream)
        return stream
    }

    func webSocket(for request: APIRequest) throws -> any WebSocketConnection { throw APIError.invalidRequest }

    /// The namespaces the fixture's pod pages accept, so a discovered name is also browsable.
    static func namespaceTable() -> Data {
        let rows = ["team", "other", "known", "empty"].map {
            #"{"cells":["\#($0)","Active","9d"],"object":{"metadata":{"name":"\#($0)","uid":"ns-\#($0)"}}}"#
        }.joined(separator: ",")
        let table = #"{"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"1","continue":""},"#
            + #""columnDefinitions":[{"name":"Name","type":"string"},{"name":"Status","type":"string"}],"#
            + #""rows":[\#(rows)]}"#
        return Data(table.utf8)
    }

    private static func details(_ request: APIRequest) throws -> Data {
        guard request.path.count == 6, request.path.prefix(3) == ["api", "v1", "namespaces"],
              request.path[3] == "team", request.path[4] == "pods",
              ["alpha", "zulu"].contains(request.path[5]), request.query.isEmpty else { throw APIError.invalidRequest }
        let name = request.path[5]
        let names = name == "alpha" ? ["web"] : ["web", "sidecar"]
        return try JSONSerialization.data(withJSONObject: [
            "apiVersion": "v1", "kind": "Pod",
            "metadata": ["uid": name == "alpha" ? "uid-a" : "uid-z", "name": name, "namespace": "team",
                         "annotations": ["kubectl.kubernetes.io/default-container": name == "alpha" ? "setup" : "sidecar"]],
            "spec": ["containers": names.map { ["name": $0] }, "initContainers": [["name": "setup"]], "ephemeralContainers": [["name": "debugger"]]],
            "status": [
                "containerStatuses": names.map { ["name": $0, "state": ["running": [:]]] as [String: Any] },
                "initContainerStatuses": [["name": "setup", "state": ["running": [:]]]],
                "ephemeralContainerStatuses": [["name": "debugger", "state": ["running": [:]]]],
            ],
        ])
    }

    static func page(namespace: String, second: Bool, empty: Bool) -> Data {
        let schema = second ? "null" : """
        [{"name":"Workload","type":"string"},{"name":"Count","type":"integer"},
         {"name":"Flag","type":"boolean"},{"name":"Workload","type":"string","priority":1},
         {"name":"Custom","type":"future","priority":2}]
        """
        let row = second
            ? #"{"cells":["alpha",2,true,"node1",null],"object":{"metadata":{"uid":"uid-a","name":"alpha","namespace":"\#(namespace)"}}}"#
            : #"{"cells":["zulu",10,false,"node2",{"a":1}],"object":{"metadata":{"uid":"uid-z","name":"zulu","namespace":"\#(namespace)"}}}"#
        return Data("""
        {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"list","continue":"\(second || empty ? "" : "next")"},
         "columnDefinitions":\(schema),"rows":[\(empty ? "" : row)]}
        """.utf8)
    }

    func modify() {
        let event = """
        {"type":"MODIFIED","object":{"apiVersion":"meta.k8s.io/v1","kind":"Table","rows":[
        {"cells":["aardvark",1,false,"node2",{"a":2}],"object":{"metadata":{"uid":"uid-z","name":"zulu","namespace":"team","resourceVersion":"next"}}}]} }
        """.replacingOccurrences(of: "\n", with: "")
        streams.last?.yield(Data((event + "\n").utf8))
    }

    private func scalePage(_ request: APIRequest) async throws -> Data {
        guard request.accept == APIRequest.tableAccept,
              request.query.contains(where: { $0.name == "limit" && $0.value == "500" }) else { throw APIError.invalidRequest }
        scaleRequests += 1
        let cursor = request.query.first { $0.name == "continue" }?.value
        if scaleRequests == 2 {
            guard cursor == "500" else { throw APIError.invalidRequest }
            try await Task.sleep(for: .milliseconds(150))
            throw APIError.http(code: 410, resource: "pods")
        }
        let start = Int(cursor ?? "0") ?? -1
        guard [0, 500, 1000].contains(start) else { throw APIError.invalidRequest }
        if start > 0 { try await Task.sleep(for: .milliseconds(150)) }
        let end = min(start + 500, 1253)
        let rows = (start..<end).map { Self.scaleRow(scaleRequests == 1 ? $0 + 9000 : $0) }
        return try JSONSerialization.data(withJSONObject: [
            "apiVersion": "meta.k8s.io/v1", "kind": "Table",
            "metadata": ["resourceVersion": scaleRelisted ? "resync-rv" : "scale-rv", "continue": end == 1253 ? "" : "\(end)"],
            "columnDefinitions": start == 0 ? [["name": "Name", "type": "string"]] as Any : NSNull(),
            "rows": rows,
        ])
    }

    /// Printed ages that are deliberately wrong, so the driver can tell a computed Age from the
    /// server's frozen text: `alpha` is two hours old but printed as `1h`.
    static func timedPage(created base: Date) -> Data {
        let rows = [
            ("alpha", "uid-a", base.addingTimeInterval(-7200), "1h"), ("zulu", "uid-z", base.addingTimeInterval(-90), "5s"),
            (longName, "uid-long", base.addingTimeInterval(-600), "10m"),
        ]
            .map { name, uid, created, printed in
                #"{"cells":["\#(name)","Running","\#(printed)"],"object":{"metadata":{"uid":"\#(uid)","name":"\#(name)","namespace":"timed","creationTimestamp":"\#(timestamp(created))"}}}"#
            }.joined(separator: ",")
        return Data("""
        {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"timed","continue":""},
         "columnDefinitions":[{"name":"Name","type":"string"},{"name":"Status","type":"string"},{"name":"Age","type":"string"}],
         "rows":[\(rows)]}
        """.utf8)
    }

    /// Shaped like a Deployment's generated pod name, and far wider than a title-sized column.
    static let longName = "checkout-admin-api-gateway-5f7b9c4d2a-x9k2p"

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func scaleRow(_ id: Int) -> [String: Any] {
        ["cells": ["pod-\(id)"], "object": ["metadata": [
            "uid": "scale-\(id)", "name": "pod-\(id)", "namespace": "scale", "resourceVersion": "event-\(id)",
        ]]]
    }

    func scaleEvent(_ type: String, id: Int) throws {
        let bytes = try JSONSerialization.data(withJSONObject: [
            "type": type, "object": ["apiVersion": "meta.k8s.io/v1", "kind": "Table", "rows": [Self.scaleRow(id)]],
        ])
        streams.last?.yield(bytes + Data([10]))
    }

    func expireScaleWatch() {
        scaleRelisted = true
        streams.last?.yield(Data(#"{"type":"ERROR","object":{"apiVersion":"v1","kind":"Status","code":410,"reason":"Expired"}}"#.utf8) + Data([10]))
    }

    func deletePod(named name: String) throws {
        guard var page = try JSONSerialization.jsonObject(
            with: Self.page(namespace: "team", second: name == "alpha", empty: false)
        ) as? [String: Any] else { throw APIError.invalidRequest }
        page["metadata"] = ["resourceVersion": "deleted-rv"]
        let event = try JSONSerialization.data(withJSONObject: ["type": "DELETED", "object": page])
        streams.last?.yield(event + Data([10]))
    }
}

/// All mutable state is protected by the lock, including cancellation-before-read.

#endif
