import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

func podPage(
    ids: [Int] = [0], version: String? = "opaque-list", cursor: String? = "",
    columns: [[String: String]]? = [["name": "Name", "type": "string"]], namespace: String = "team"
) throws -> Data {
    var metadata: [String: String] = [:]
    metadata["resourceVersion"] = version
    metadata["continue"] = cursor
    var table: [String: Any] = [
        "apiVersion": "meta.k8s.io/v1", "kind": "Table", "metadata": metadata,
        "rows": ids.map { id in
            ["cells": ["pod-\(id)"], "object": ["metadata": [
                "uid": "uid-\(id)", "name": "pod-\(id)", "namespace": namespace, "resourceVersion": "row-\(id)",
            ]]] as [String: Any]
        },
    ]
    table["columnDefinitions"] = columns ?? NSNull()
    return try JSONSerialization.data(withJSONObject: table, options: [.sortedKeys])
}

func podEvent(_ type: String = "MODIFIED", id: Int = 0, version: String = "opaque-next", columns: Bool = false) throws -> Data {
    let table = try JSONSerialization.jsonObject(with: podPage(
        ids: [id], version: version, columns: columns ? [["name": "Name", "type": "string"]] : nil
    ))
    var data = try JSONSerialization.data(withJSONObject: ["type": type, "object": table], options: [.sortedKeys])
    data.append(10)
    return data
}

/// A deployments Table as the apiserver prints one: the kubectl printer's columns, with AGE marked
/// the way a server marks it so the presentation's synthetic Age has something to recognise.
func deploymentColumns(wide: Bool = false) -> [[String: Any]] {
    var columns: [[String: Any]] = [
        ["name": "Name", "type": "string", "format": "name"],
        ["name": "Ready", "type": "string"],
        ["name": "Up-to-date", "type": "string"],
        ["name": "Available", "type": "string"],
        ["name": "Age", "type": "string"],
    ]
    if wide {
        columns += [
            ["name": "Containers", "type": "string", "priority": 1],
            ["name": "Images", "type": "string", "priority": 1],
            ["name": "Selector", "type": "string", "priority": 1],
        ]
    }
    return columns
}

func deploymentPage(
    ids: [Int] = [0], version: String? = "opaque-list", cursor: String? = "",
    columns: [[String: Any]]? = deploymentColumns(), namespace: String = "team",
    created: String? = "2026-10-01T00:00:00Z"
) throws -> Data {
    var metadata: [String: String] = [:]
    metadata["resourceVersion"] = version
    metadata["continue"] = cursor
    var table: [String: Any] = [
        "apiVersion": "meta.k8s.io/v1", "kind": "Table", "metadata": metadata,
        "rows": ids.map { id in
            var object: [String: Any] = [
                "uid": "deploy-uid-\(id)", "name": "deploy-\(id)", "namespace": namespace,
                "resourceVersion": "row-\(id)",
            ]
            if let created { object["creationTimestamp"] = created }
            return ["cells": ["deploy-\(id)", "3/3", "3", "3", "6d"], "object": ["metadata": object]] as [String: Any]
        },
    ]
    table["columnDefinitions"] = columns ?? NSNull()
    return try JSONSerialization.data(withJSONObject: table, options: [.sortedKeys])
}

func deploymentEvent(_ type: String = "MODIFIED", id: Int = 0, version: String = "opaque-next", columns: Bool = false) throws -> Data {
    let table = try JSONSerialization.jsonObject(with: deploymentPage(
        ids: [id], version: version, columns: columns ? deploymentColumns() : nil
    ))
    var data = try JSONSerialization.data(withJSONObject: ["type": type, "object": table], options: [.sortedKeys])
    data.append(10)
    return data
}

func podStatus(_ code: Int) -> Data {
    Data("""
    {"type":"ERROR","object":{"apiVersion":"v1","kind":"Status","status":"Failure","code":\(code)}}

    """.utf8)
}

func podQuery(_ request: APIRequest) -> [String: String] {
    Dictionary(uniqueKeysWithValues: request.query.map { ($0.name, $0.value ?? "") })
}

actor WatchTestTransport: Transport {
    typealias DataHandler = @Sendable (APIRequest, Int) async throws -> Data
    typealias StreamHandler = @Sendable (APIRequest, Int) async throws -> any HTTPByteStream
    private let onData: DataHandler
    private let onStream: StreamHandler
    private(set) var requests: [APIRequest] = []
    private(set) var streams: [APIRequest] = []
    private(set) var invalidations: [APIError] = []
    private(set) var cancelledPages = 0
    private(set) var cancelledOpens = 0

    init(
        data: @escaping DataHandler = { _, _ in try podPage() },
        stream: @escaping StreamHandler = { _, _ in MemoryByteStream() }
    ) {
        onData = data
        onStream = stream
    }

    func data(for request: APIRequest) async throws -> Data {
        requests.append(request)
        do { return try await onData(request, requests.count) } catch {
            if Task.isCancelled { cancelledPages += 1 }
            throw error
        }
    }

    func stream(for request: APIRequest, purpose: TransportPurpose) async throws -> any HTTPByteStream {
        #expect(purpose == .watch)
        streams.append(request)
        do { return try await onStream(request, streams.count) } catch {
            if Task.isCancelled { cancelledOpens += 1 }
            throw error
        }
    }

    func invalidateCredentials(after error: APIError) { invalidations.append(error) }
    func webSocket(for request: APIRequest) throws -> any WebSocketConnection { throw APIError.invalidRequest }
}

@MainActor final class PodUpdateCapture {
    var values: [ResourceListUpdate] = []
}

struct RecordingPodWatcher: ResourceWatching {
    let service: WatchService
    let capture: PodUpdateCapture
    func run(
        kind: ResourceKind, context: ResolvedContext, namespace: String,
        update: @escaping @MainActor @Sendable (ResourceListUpdate) -> Void
    ) async {
        await service.run(kind: kind, context: context, namespace: namespace) { value in
            capture.values.append(value)
            update(value)
        }
    }
}

@MainActor final class WatchTestOwner {
    let store: AppStore
    let actions: AppActions
    let capture = PodUpdateCapture()
    let clock: ManualTransportClock

    init(transport: any Transport, clock: ManualTransportClock = ManualTransportClock()) throws {
        self.clock = clock
        let contexts = try ["first", "second"].map { name in
            try Kubeconfig(
                currentContext: name, clusters: [.init(name: name, cluster: .init(server: "https://synthetic.invalid"))],
                contexts: [.init(name: name, context: .init(cluster: name, namespace: "team"))]
            ).resolve()
        }
        store = AppStore(contexts: contexts)
        actions = AppActions(
            store: store, exec: UnusedPodExec(), authentication: UnusedPodAuth(), surfaces: UnusedPodSurface(),
            lists: RecordingPodWatcher(service: WatchService(transports: { _ in transport }, clock: clock, jitter: { 1 }), capture: capture)
        )
    }

    func start(_ kind: ResourceKind = .pods) { actions.refreshList(kind) }
    func stop() async { await actions.shutdownAndWait() }
}

private struct UnusedPodExec: ExecSessionControlling {
    func run(
        sessionID: UUID, target: ExecTarget, ready: @escaping @MainActor @Sendable (ExecBridgeEndpoint) throws -> Void,
        update: @escaping @MainActor @Sendable (ExecSession.State) -> Void
    ) async -> ExecSessionResult { .failed(.api(.invalidRequest)) }
    func childTerminated(sessionID: UUID) {}
}

@MainActor private struct UnusedPodSurface: TerminalSurfaceCreating {
    func makeSurface(
        sessionID: UUID, target: ExecTarget, endpoint: ExecBridgeEndpoint,
        onChildExit: @escaping @MainActor @Sendable () -> Void
    ) throws -> any TerminalSurface { throw APIError.invalidRequest }
}

private struct UnusedPodAuth: AuthenticationControlling {
    func update(settings: AuthSettings) {}
    func acquire(for context: ResolvedContext) throws -> AcquiredCredential { throw APIError.invalidRequest }
    func signIn(for context: ResolvedContext, useDeviceCode: Bool) throws -> AcquiredCredential { throw APIError.invalidRequest }
    func sessions() -> AsyncStream<AuthSession> { AsyncStream { $0.finish() } }
    func cancel(operationID: UUID) {}
    func retry(operationID: UUID) throws -> AcquiredCredential { throw APIError.invalidRequest }
}

@MainActor func watchEventually(_ predicate: @escaping @MainActor () async -> Bool) async throws {
    try await transportEventually { await predicate() }
}
