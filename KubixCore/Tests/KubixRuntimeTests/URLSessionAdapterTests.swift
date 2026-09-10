import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

func loopbackRequest(_ server: LoopbackTransportServer, socket: Bool = false) throws -> URLRequest {
    var request = URLRequest(url: try #require(URL(string: "\(socket ? "ws" : "http")://127.0.0.1:\(server.port)/synthetic")))
    request.setValue("Bearer synthetic-local-only", forHTTPHeaderField: "Authorization")
    if socket { request.setValue("v5.channel.k8s.io", forHTTPHeaderField: "Sec-WebSocket-Protocol") }
    request.timeoutInterval = 5
    return request
}

func localSession(purpose: TransportPurpose = .logs) throws -> URLSessionHTTPClient {
    let policy = try ClusterTrustPolicy(cluster: KubeconfigCluster(server: "http://127.0.0.1"), authorityData: nil)
    return URLSessionHTTPClient(purpose: purpose, trust: policy)
}

@Test func nativeFoundationDataAndByteAdaptersUseSyntheticLoopbackOnly() async throws {
    let session = try localSession()
    let dataServer = try LoopbackTransportServer(reply: .http(403, "synthetic forbidden"))
    defer { dataServer.stop() }
    let response = try await session.data(for: loopbackRequest(dataServer))
    #expect(response.statusCode == 403)
    #expect(response.body == Data("synthetic forbidden".utf8))
    try await dataServer.wait()
    #expect(dataServer.request.lowercased().contains("authorization: bearer synthetic-local-only"))

    let streamServer = try LoopbackTransportServer(reply: .http(200, "one\né\n"))
    defer { streamServer.stop() }
    let stream = try await session.stream(for: loopbackRequest(streamServer))
    #expect(stream.statusCode == 200)
    var bytes = Data()
    while let chunk = try await stream.body.read() { bytes.append(chunk) }
    #expect(bytes == Data("one\né\n".utf8))
    stream.body.cancel()
    try await streamServer.wait()
}

@Test(arguments: [TransportPurpose.logs, .request])
func nativeLogAdapterDeliversBoundedBytesAfterConsumerPausesAndCancels(_ purpose: TransportPurpose) async throws {
    let session = try localSession(purpose: purpose)
    let server = try LoopbackTransportServer(reply: .http(200, String(repeating: "é\n", count: 300)))
    defer { server.stop() }
    let response = try await session.stream(for: loopbackRequest(server))
    defer { response.body.cancel() }
    var count = 0
    for _ in 0..<900 {
        let bytes = try #require(try await response.body.read())
        #expect(bytes.count == 1)
        count += bytes.count
        await Task.yield()
    }
    #expect(count == 900)
    #expect(try await response.body.read() == nil)
    response.body.cancel()
    try await server.wait()
}

@Test(arguments: [TransportEntry.data, .stream])
func nativeFoundationHTTPAdaptersPreserveRetryAfterFromLoopback(_ entry: TransportEntry) async throws {
    let server = try LoopbackTransportServer(reply: .http(429, "synthetic throttling", retryAfter: "45"))
    defer { server.stop() }
    let session = try localSession()
    switch entry {
    case .data:
        let response = try await session.data(for: loopbackRequest(server))
        #expect(response.statusCode == 429 && response.retryAfter == "45")
    case .stream:
        let response = try await session.stream(for: loopbackRequest(server))
        defer { response.body.cancel() }
        #expect(response.statusCode == 429 && response.retryAfter == "45")
    case .socket: Issue.record("Not an HTTP adapter")
    }
    try await server.wait()
}

@Test func nativeFoundationWebSocketNegotiatesAuthenticatedRequestAndBinaryPingIO() async throws {
    let server = try LoopbackTransportServer(reply: .websocket)
    defer { server.stop() }
    let session = try localSession()
    let connection = try await session.connect(request: loopbackRequest(server, socket: true))
    defer { connection.cancel() }
    #expect(connection.negotiatedProtocol == "v5.channel.k8s.io")
    #expect(server.request.lowercased().contains("authorization: bearer synthetic-local-only"))
    #expect(server.request.lowercased().contains("sec-websocket-protocol: v5.channel.k8s.io"))
    #expect(try await connection.receive() == Data([1, 65, 66]))
    try await connection.send(Data([0, 67]))
    let clock = ContinuousTransportClock()
    do {
        try await withTransportDeadline(until: clock.now + 3, clock: clock, cancel: connection.cancel) {
            try await connection.ping()
        }
    } catch {
        Issue.record("Native ping: \(error); frames: \(server.frames)")
        try await server.wait()
        throw error
    }
    #expect(server.receivedBinary == Data([0, 67]))
    #expect(server.receivedPing)
    connection.cancel()
    try await server.wait()
}

@Test(arguments: [401, 403])
func nativeFoundationFailedUpgradeDoesNotInventStatusBody(_ code: Int) async throws {
    let server = try LoopbackTransportServer(reply: .http(code, #"{"apiVersion":"v1","kind":"Status","code":401}"#))
    defer { server.stop() }
    let session = try localSession()
    do {
        let connection = try await session.connect(request: loopbackRequest(server, socket: true))
        connection.cancel()
        Issue.record("Unexpected upgrade")
    } catch let error as WebSocketHandshakeError {
        #expect(error.statusCode == code)
        #expect(error.body.isEmpty)
        print("Synthetic Foundation upgrade \(code): task.response status available; response body unavailable.")
    } catch let error as APIError {
        // Apple Foundation versions differ. If task.response is absent, a 401 retry is
        // impossible to justify. Production must expose this limitation, not probe/replay exec.
        #expect(error == .transport(.upgradeResponseUnavailable))
        print("Synthetic Foundation upgrade \(code): task.response unavailable; authentication retry correctly disabled.")
    }
    try await server.wait()
}

@Test(arguments: TransportEntry.allCases)
func nativeFoundationPendingIORespondsToCancellation(_ entry: TransportEntry) async throws {
    let server = try LoopbackTransportServer(reply: .quiet)
    defer { server.stop() }
    let session = try localSession()
    let request = try loopbackRequest(server, socket: entry == .socket)
    let work = Task {
        switch entry {
        case .data: _ = try await session.data(for: request)
        case .stream: try await session.stream(for: request).body.cancel()
        case .socket: try await session.connect(request: request).cancel()
        }
    }
    try await transportEventually { !server.request.isEmpty }
    work.cancel()
    await #expect(throws: CancellationError.self) { try await work.value }
    try await server.wait()
}

@Test func nativeCallbackCancellationDoesNotWaitForMissingPingCallback() async throws {
    let promise = TransportPromise<Void>()
    let work = Task { try await promise.value(cancel: {}) }
    work.cancel()
    await #expect(throws: CancellationError.self) { try await work.value }
    promise.finish(.success(()))
}
