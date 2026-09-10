import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@MainActor final class LogCapture {
    var opened = false
    var lines: [DecodedLogLine] = []
    var largestBatch = 0
    func receive(_ event: LogEvent) {
        switch event {
        case .opened: opened = true
        case .lines(let batch): lines += batch; largestBatch = max(largestBatch, batch.count)
        }
    }
}

func logTestTarget() throws -> LogTarget {
    let pod = try JSONDecoder().decode(PodDetails.self, from: podDetailsData())
    return try LogTarget(context: transportConfiguration().resolve(), details: pod, container: #require(pod.containers.first))
}

@MainActor func runLog(_ transport: any Transport, capture: LogCapture, follow: Bool = true) throws -> Task<LogOutcome, Never> {
    let target = try logTestTarget()
    let request = try LogRequest(namespace: target.namespace, pod: target.pod, container: target.container.name, follow: follow)
    let service = LogService { _ in transport }
    return Task { await service.run(target: target, request: request) { capture.receive($0) } }
}

@Suite @MainActor struct LogServiceTests {
    @Test func authenticatedFollowUsesLongProfileAndSplitUTF8CleanEOF() async throws {
        let bytes = Array("hello 🙂\npartial".utf8)
        let stream = MemoryByteStream(bytes.map { Data([$0]) }, finished: true)
        let session = ScriptedTransportSession(stream: { _, _ in HTTPStreamResponse(statusCode: 200, body: stream) })
        let credentials = TransportCredentials()
        let transport = try await testTransport(session: session, credentials: credentials)
        let capture = LogCapture()
        let work = try runLog(transport, capture: capture)
        #expect(await work.value == .completed)
        #expect(capture.opened && capture.lines.map(\.text) == ["hello 🙂", "partial"])
        #expect(capture.lines.allSatisfy { !$0.repairedUTF8 })
        let request = try #require(await session.streamRequests.first)
        #expect(request.timeoutInterval == 86_400)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") != nil)
        #expect(request.url?.path == "/api/v1/namespaces/team/pods/pod-0/log")
        #expect(stream.cancelled)
        #expect(await credentials.acquisitions == 1)
    }

    @Test(arguments: [400, 401, 403, 404, 500])
    func serverFailuresAreDistinctAndPayloadFree(_ code: Int) async throws {
        let session = ScriptedTransportSession(stream: { _, _ in
            HTTPStreamResponse(statusCode: code, body: MemoryByteStream([Data("""
            {"apiVersion":"v1","kind":"Status","message":"NEVER-RETAIN-SERVER-PAYLOAD","reason":"Synthetic"}
            """.utf8)], finished: true))
        })
        let transport = try await testTransport(session: session)
        let capture = LogCapture()
        let work = try runLog(transport, capture: capture)
        let expected = LogFailure.classify(APIError.http(code: code, resource: "pods/log"))
        #expect(await work.value == .failed(expected))
        #expect(!capture.opened && capture.lines.isEmpty)
        #expect(!expected.diagnostic.contains("NEVER-RETAIN"))
        #expect(await session.streamRequests.count == (code == 401 ? 2 : 1))
    }

    @Test func quietBeyondMinuteRemainsFollowingThenIdleDeadlineInterruptsAndFlushesPartial() async throws {
        let clock = ManualTransportClock()
        let stream = MemoryByteStream([Data("kept\nunfinished".utf8)])
        let session = ScriptedTransportSession(stream: { _, _ in HTTPStreamResponse(statusCode: 200, body: stream) })
        let transport = try await testTransport(session: session, clock: clock)
        let capture = LogCapture()
        let work = try runLog(transport, capture: capture)
        try await transportEventually { stream.isWaiting && clock.deadlines.contains(86_400) }
        clock.advance(to: 61)
        #expect(capture.opened && !stream.cancelled && capture.lines.map(\.text) == ["kept"])
        #expect(clock.deadlines == [86_400])
        clock.advance(to: 86_400)
        #expect(await work.value == .interrupted(.deadline))
        #expect(capture.lines.map(\.text) == ["kept", "unfinished"])
        #expect(stream.cancelled && clock.deadlines.isEmpty)
    }

    @Test func activityDoesNotExtendSevenDayResourceLimit() async throws {
        let clock = ManualTransportClock()
        let stream = MemoryByteStream()
        let session = ScriptedTransportSession(stream: { _, _ in HTTPStreamResponse(statusCode: 200, body: stream) })
        let transport = try await testTransport(session: session, clock: clock)
        let capture = LogCapture()
        let work = try runLog(transport, capture: capture)
        for index in 1...7 {
            try await transportEventually { stream.isWaiting && !clock.deadlines.isEmpty }
            clock.advance(to: Double(index * 80_000))
            stream.yield(Data("tick\n".utf8))
            try await transportEventually { await capture.lines.count == index }
        }
        try await transportEventually { stream.isWaiting && clock.deadlines == [604_800] }
        clock.advance(to: 604_800)
        #expect(await work.value == .interrupted(.deadline))
        #expect(capture.lines.count == 7 && clock.deadlines.isEmpty)
    }

    @Test func finiteProfileAndCancellationAreNotCleanEOF() async throws {
        let clock = ManualTransportClock()
        let stream = MemoryByteStream()
        let session = ScriptedTransportSession(stream: { _, _ in HTTPStreamResponse(statusCode: 200, body: stream) })
        let transport = try await testTransport(session: session, clock: clock)
        let work = try runLog(transport, capture: LogCapture(), follow: false)
        try await transportEventually { stream.isWaiting && clock.deadlines == [30] }
        #expect(await session.streamRequests.first?.timeoutInterval == 30)
        work.cancel()
        #expect(await work.value == .cancelled)
        #expect(stream.cancelled && clock.deadlines.isEmpty)
    }

    @Test func boundedChunksBatchesAndUnfinishedLines() async throws {
        let chunks = [Data(repeating: 65, count: 65_536), Data(repeating: 65, count: 65_536), Data("\n".utf8), Data(repeating: 10, count: 1000)]
        let stream = MemoryByteStream(chunks, finished: true)
        let transport = LogTestTransport(stream: { _, _ in stream })
        let capture = LogCapture()
        let work = try runLog(transport, capture: capture)
        #expect(await work.value == .completed)
        #expect(capture.lines.first?.text.utf8.count == 16_384 && capture.lines.first?.truncated == true)
        #expect(capture.lines.count == 1001 && capture.largestBatch <= 64)
        let overflow = MemoryByteStream([Data("kept\n".utf8), Data(repeating: 65, count: 65_537)])
        let second = LogCapture()
        #expect(await (try runLog(LogTestTransport(stream: { _, _ in overflow }), capture: second)).value == .interrupted(.overflow))
        #expect(second.lines.map(\.text) == ["kept"] && overflow.cancelled)
    }

    @Test func readFailurePreservesLinesAndDoesNotClaimCompletion() async throws {
        let capture = LogCapture()
        let work = try runLog(LogTestTransport(stream: { _, _ in FailingLogStream() }), capture: capture)
        #expect(await work.value == .interrupted(.transport))
        #expect(capture.lines.map(\.text) == ["retained", "partial"])
    }

    @Test(arguments: [true, false])
    func lateFactoryOrOpenIsCancelledBeforeConsuming(factory: Bool) async throws {
        let gate = UncooperativeWatchGate()
        let bytes = MemoryByteStream()
        let transport = LogTestTransport(stream: { _, _ in
            if !factory { await gate.wait() }
            return bytes
        })
        let service = LogService { _ in
            if factory { await gate.wait() }
            return transport
        }
        let target = try logTestTarget()
        let request = try LogRequest(namespace: "team", pod: "pod-0", container: "web")
        let capture = LogCapture()
        let work = Task { await service.run(target: target, request: request) { capture.receive($0) } }
        try await transportEventually { await gate.isWaiting }
        work.cancel()
        await gate.open()
        #expect(await work.value == .cancelled)
        #expect(!capture.opened && capture.lines.isEmpty)
        #expect(await transport.streams.count == (factory ? 0 : 1))
        if !factory { #expect(bytes.cancelled) }
    }

    @Test func immutableTargetMismatchCannotAcquireTransport() async throws {
        let service = LogService { _ in Issue.record("Mismatched target acquired transport"); throw APIError.invalidRequest }
        let target = try logTestTarget()
        let request = try LogRequest(namespace: "other", pod: "replacement", container: "web")
        #expect(await service.run(target: target, request: request, receive: { _ in Issue.record("Mismatched target delivered event") }) == .failed(.invalidTarget))
    }

    @Test func unsolicitedCancellationIsInterruptionNotUserPause() async throws {
        let stream = UnsolicitedLogCancellation()
        let capture = LogCapture()
        let work = try runLog(LogTestTransport(stream: { _, _ in stream }), capture: capture)
        #expect(await work.value == .interrupted(.transport))
        #expect(capture.opened)
    }

    @Test func sharedTransportRefreshes401OnceBeforeOpeningWithoutBrowserController() async throws {
        let credentials = TransportCredentials()
        let session = ScriptedTransportSession(stream: { _, call in
            HTTPStreamResponse(statusCode: call == 1 ? 401 : 200, body: MemoryByteStream([], finished: true))
        })
        let transport = try await testTransport(session: session, credentials: credentials)
        let capture = LogCapture()
        #expect(await (try runLog(transport, capture: capture)).value == .completed)
        #expect(capture.opened && capture.lines.isEmpty)
        #expect(await credentials.acquisitions == 2)
        #expect(await credentials.acceptedInvalidations == 1)
        #expect(await session.streamRequests.count == 2)
    }

    @Test func cancellationDuringSharedCredentialAcquisitionOpensNoLogRequest() async throws {
        let gate = TestGate()
        let credentials = TransportCredentials(gate: gate)
        let session = ScriptedTransportSession()
        let transport = try await testTransport(session: session, credentials: credentials)
        let capture = LogCapture()
        let work = try runLog(transport, capture: capture)
        try await transportEventually { await credentials.acquisitions == 1 }
        work.cancel()
        #expect(await work.value == .cancelled)
        #expect(await session.streamRequests.isEmpty)
        #expect(!capture.opened)
    }

    @Test(arguments: [true, false])
    func rawReadErrorsAreNormalizedWithoutPayload(deadline: Bool) async throws {
        let stream = FailingLogStream(error: URLError(deadline ? .timedOut : .networkConnectionLost))
        let capture = LogCapture()
        let work = try runLog(LogTestTransport(stream: { _, _ in stream }), capture: capture)
        #expect(await work.value == .interrupted(deadline ? .deadline : .transport))
        #expect(capture.lines.count == 2)
    }
}

private struct UnsolicitedLogCancellation: HTTPByteStream {
    func read() throws -> Data? { throw CancellationError() }
    func cancel() {}
}

private actor FailingLogStream: HTTPByteStream {
    var count = 0
    let error: any Error
    init(error: any Error = APIError.transport(.connection)) { self.error = error }
    func read() throws -> Data? {
        count += 1
        if count == 1 { return Data("retained\npartial".utf8) }
        throw error
    }
    nonisolated func cancel() {}
}
