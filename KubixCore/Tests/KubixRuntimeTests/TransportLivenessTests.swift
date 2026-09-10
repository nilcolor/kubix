import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Test func finiteRequestHasBoundedTotalBudgetAndCleansTimer() async throws {
    let clock = ManualTransportClock()
    let gate = TestGate()
    let session = ScriptedTransportSession(data: { _, _ in
        try await gate.wait()
        return HTTPDataResponse(statusCode: 200, body: Data())
    })
    let transport = try await testTransport(session: session, clock: clock)
    let work = Task { try await transport.data(for: podsRequest) }
    try await transportEventually { clock.deadlines == [60] }
    clock.advance(to: 59)
    #expect(clock.deadlines == [60])
    clock.advance(to: 60)
    await #expect(throws: APIError.transport(.timedOut)) { try await work.value }
    #expect(clock.deadlines.isEmpty)
    #expect(await session.requests.first?.timeoutInterval == 30)
}

@Test func quietLogFollowSurvives60SecondsAndHasExplicitIdleLimit() async throws {
    let clock = ManualTransportClock()
    let bytes = MemoryByteStream()
    let session = ScriptedTransportSession(stream: { _, _ in HTTPStreamResponse(statusCode: 200, body: bytes) })
    let transport = try await testTransport(session: session, clock: clock)
    let stream = try await transport.stream(for: podsRequest, purpose: .logs)
    let read = Task { try await stream.read() }
    try await transportEventually { bytes.isWaiting && clock.deadlines == [86_400] }
    clock.advance(to: 61)
    #expect(!bytes.cancelled)
    bytes.yield(Data("quiet log arrived".utf8))
    #expect(try await read.value == Data("quiet log arrived".utf8))
    let next = Task { try await stream.read() }
    try await transportEventually { bytes.isWaiting && clock.deadlines == [86_461] }
    clock.advance(to: 86_461)
    await #expect(throws: APIError.transport(.timedOut)) { try await next.value }
    #expect(bytes.cancelled)
    #expect(clock.deadlines.isEmpty)
    #expect(await session.streamRequests.first?.timeoutInterval == 86_400)
}

@Test func logResourceBudgetDoesNotResetOnActivity() async throws {
    let clock = ManualTransportClock()
    let bytes = MemoryByteStream()
    let policy = TransportPolicy.policy(for: .logs)
    let stream = PolicyByteStream(underlying: bytes, policy: policy, started: 0, clock: clock)
    for day in 1...7 {
        let read = Task { try await stream.read() }
        try await transportEventually { bytes.isWaiting && !clock.deadlines.isEmpty }
        clock.advance(to: Double(day) * 86_399)
        bytes.yield(Data([65]))
        _ = try await read.value
    }
    let last = Task { try await stream.read() }
    try await transportEventually { clock.deadlines == [604_800] }
    clock.advance(to: 604_800)
    await #expect(throws: APIError.transport(.timedOut)) { try await last.value }
    #expect(bytes.cancelled)
}

@Test func watchLeaseEOFAndNewRequestReceiveFresh330SecondBudgets() async throws {
    let clock = ManualTransportClock()
    let first = MemoryByteStream()
    let second = MemoryByteStream()
    let session = ScriptedTransportSession(stream: { _, count in
        HTTPStreamResponse(statusCode: 200, body: count == 1 ? first : second)
    })
    let transport = try await testTransport(session: session, clock: clock)
    let stream = try await transport.stream(for: podsRequest, purpose: .watch)
    let read = Task { try await stream.read() }
    try await transportEventually { clock.deadlines == [330] && first.isWaiting }
    clock.advance(to: 300)
    first.yield(nil)
    #expect(try await read.value == nil)
    #expect(first.cancelled)
    let renewed = try await transport.stream(for: podsRequest, purpose: .watch)
    let next = Task { try await renewed.read() }
    try await transportEventually { clock.deadlines == [630] }
    clock.advance(to: 630)
    await #expect(throws: APIError.transport(.timedOut)) { try await next.value }
    let requests = await session.streamRequests
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.timeoutInterval == 330 && $0.url?.query == "timeoutSeconds=300" })
}

@Test func streamCancellationUnblocksReadAndRemovesTimers() async throws {
    let clock = ManualTransportClock()
    let bytes = MemoryByteStream()
    let session = ScriptedTransportSession(stream: { _, _ in HTTPStreamResponse(statusCode: 200, body: bytes) })
    let transport = try await testTransport(session: session, clock: clock)
    let stream = try await transport.stream(for: podsRequest, purpose: .logs)
    let read = Task { try await stream.read() }
    try await transportEventually { bytes.isWaiting && !clock.deadlines.isEmpty }
    read.cancel()
    await #expect(throws: CancellationError.self) { try await read.value }
    #expect(bytes.cancelled)
    #expect(clock.deadlines.isEmpty)
}

@Test func authenticationWaitDoesNotConsumeUpgradeDeadline() async throws {
    let clock = ManualTransportClock()
    let auth = TestGate()
    let upgrade = TestGate()
    let credentials = TransportCredentials(gate: auth)
    let session = ScriptedTransportSession(socket: { _, _ in
        try await upgrade.wait()
        return TransportSocket()
    })
    let transport = try await testTransport(session: session, credentials: credentials, clock: clock)
    let work = Task { try await transport.webSocket(for: execRequest) }
    try await transportEventually { await credentials.acquisitions == 1 }
    clock.advance(to: 120)
    #expect(clock.deadlines.isEmpty)
    #expect(await session.socketRequests.isEmpty)
    await auth.open()
    try await transportEventually { clock.deadlines == [150] }
    clock.advance(to: 149)
    #expect(clock.deadlines == [150])
    clock.advance(to: 150)
    await #expect(throws: APIError.transport(.upgradeTimedOut)) { try await work.value }
    #expect(clock.deadlines.isEmpty)
}

@Test func healthyHeartbeatUsesIndependent15SecondCadence() async throws {
    let clock = ManualTransportClock()
    let socket = TransportSocket(blockedSend: true)
    let connection = HeartbeatWebSocket(connection: socket, clock: clock)
    let send = Task { try await connection.send(Data([1])) }
    try await transportEventually { clock.deadlines == [15] && socket.sends == 1 }
    for tick in 1...5 {
        clock.advance(to: Double(tick) * 15)
        try await transportEventually {
            socket.pings == tick && clock.waitCount == 1 + tick * 2 && clock.deadlines == [Double(tick + 1) * 15]
        }
        #expect(!socket.cancelled)
    }
    connection.cancel()
    await #expect(throws: CancellationError.self) { try await send.value }
    try await transportEventually { clock.deadlines.isEmpty }
}

@Test func silentBlackholeFailsPendingReceiveAndSendWithoutExecReplay() async throws {
    let clock = ManualTransportClock()
    let socket = TransportSocket(ping: .blackhole, blockedSend: true)
    let session = ScriptedTransportSession(socket: { _, _ in socket })
    let transport = try await testTransport(session: session, clock: clock)
    let connection = try await transport.webSocket(for: execRequest)
    let receive = Task { try await connection.receive() }
    let send = Task { try await connection.send(Data([0])) }
    try await transportEventually { clock.deadlines == [15] && socket.incoming.isWaiting && socket.sends == 1 }
    clock.advance(to: 15)
    try await transportEventually { socket.pings == 1 && clock.deadlines == [30] }
    clock.advance(to: 30)
    await #expect(throws: APIError.transport(.pongTimedOut)) { try await receive.value }
    await #expect(throws: APIError.transport(.pongTimedOut)) { try await send.value }
    #expect(socket.cancelled)
    socket.deliverPong()
    await #expect(throws: APIError.transport(.pongTimedOut)) { try await connection.send(Data()) }
    #expect(await session.socketRequests.count == 1)
    try await transportEventually { clock.deadlines.isEmpty }
}

@Test func pingSendFailureIsVisibleAndTimerStops() async throws {
    let clock = ManualTransportClock()
    let socket = TransportSocket(ping: .failure)
    let connection = HeartbeatWebSocket(connection: socket, clock: clock)
    let receive = Task { try await connection.receive() }
    try await transportEventually { clock.deadlines == [15] && socket.incoming.isWaiting }
    clock.advance(to: 15)
    await #expect(throws: APIError.transport(.pingFailed)) { try await receive.value }
    #expect(socket.cancelled)
    try await transportEventually { clock.deadlines.isEmpty }
}

@Test func timelyPongRenewsHeartbeatAndCancellationRemovesPongTimer() async throws {
    let clock = ManualTransportClock()
    let socket = TransportSocket(ping: .blackhole)
    let connection = HeartbeatWebSocket(connection: socket, clock: clock)
    try await transportEventually { clock.deadlines == [15] }
    clock.advance(to: 15)
    try await transportEventually { clock.deadlines == [30] }
    clock.advance(to: 29)
    socket.deliverPong()
    try await transportEventually { clock.deadlines == [44] }
    #expect(!socket.cancelled)
    connection.cancel()
    try await transportEventually { clock.deadlines.isEmpty }

    let second = HeartbeatWebSocket(connection: TransportSocket(ping: .blackhole), clock: clock)
    try await transportEventually { clock.deadlines == [44] }
    clock.advance(to: 44)
    try await transportEventually { clock.deadlines == [59] }
    second.cancel()
    try await transportEventually { clock.deadlines.isEmpty }
}

@Test func cancellingAuthAndUpgradeWaitsLeavesNoTransportTimers() async throws {
    let clock = ManualTransportClock()
    let auth = TestGate()
    let credentials = TransportCredentials(gate: auth)
    let session = ScriptedTransportSession()
    let transport = try await testTransport(session: session, credentials: credentials, clock: clock)
    let work = Task { try await transport.webSocket(for: execRequest) }
    try await transportEventually { await credentials.acquisitions == 1 }
    work.cancel()
    await #expect(throws: CancellationError.self) { try await work.value }
    #expect(clock.deadlines.isEmpty)
    #expect(await session.socketRequests.isEmpty)

    let upgrade = TestGate()
    let pending = ScriptedTransportSession(socket: { _, _ in try await upgrade.wait(); return TransportSocket() })
    let other = try await testTransport(session: pending, clock: clock)
    let upgrading = Task { try await other.webSocket(for: execRequest) }
    try await transportEventually { clock.deadlines == [30] }
    upgrading.cancel()
    await #expect(throws: CancellationError.self) { try await upgrading.value }
    #expect(clock.deadlines.isEmpty)
}

@Test func errorBodyReadIsBoundedAndCancellationIsNotReportedAs403() async throws {
    let clock = ManualTransportClock()
    let body = MemoryByteStream()
    let session = ScriptedTransportSession(stream: { _, _ in HTTPStreamResponse(statusCode: 403, body: body) })
    let transport = try await testTransport(session: session, clock: clock)
    let work = Task { try await transport.stream(for: podsRequest, purpose: .logs) }
    try await transportEventually { body.isWaiting && clock.deadlines.contains(30) }
    work.cancel()
    await #expect(throws: CancellationError.self) { try await work.value }
    #expect(body.cancelled)
    #expect(clock.deadlines.isEmpty)

    let slow = MemoryByteStream()
    let other = try await testTransport(session: ScriptedTransportSession(stream: { _, _ in
        HTTPStreamResponse(statusCode: 403, body: slow)
    }), clock: clock)
    let timed = Task { try await other.stream(for: podsRequest, purpose: .logs) }
    try await transportEventually { slow.isWaiting && clock.deadlines.contains(30) }
    clock.advance(to: 30)
    await #expect(throws: APIError.http(code: 403, resource: podsRequest.resourceContext)) { try await timed.value }
    #expect(slow.cancelled)
    #expect(clock.deadlines.isEmpty)
}

@Test func elapsedResourceBudgetFailsBeforeReadingBufferedBytes() async throws {
    let clock = ManualTransportClock()
    let bytes = MemoryByteStream([Data([65])], finished: true)
    let stream = PolicyByteStream(underlying: bytes, policy: .policy(for: .watch), started: 0, clock: clock)
    clock.advance(to: 331)
    await #expect(throws: APIError.transport(.timedOut)) { try await stream.read() }
    #expect(bytes.cancelled)
    #expect(clock.deadlines.isEmpty)
}
