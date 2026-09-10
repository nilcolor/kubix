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
    var values: [PodWatchUpdate] = []
}

struct RecordingPodWatcher: PodWatching {
    let service: WatchService
    let capture: PodUpdateCapture
    func run(
        context: ResolvedContext, namespace: String, update: @escaping @MainActor @Sendable (PodWatchUpdate) -> Void
    ) async {
        await service.run(context: context, namespace: namespace) { value in
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
            pods: RecordingPodWatcher(service: WatchService(transports: { _ in transport }, clock: clock, jitter: { 1 }), capture: capture)
        )
    }

    func start() { actions.refreshPods() }
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
