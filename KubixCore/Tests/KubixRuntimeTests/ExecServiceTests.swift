import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Suite @MainActor struct ExecServiceTests {
    @Test func initialHandshakeAndRemoteResizePrecedeInputWithHalfCloseAndOutputOrder() async throws {
        let initial = TestGate()
        let output = TestGate()
        let bridge = try ExecTestBridge(initialGate: initial, outputGate: output)
        let bridges = ExecTestBridges(bridge)
        let socket = ExecTestSocket()
        let transport = ExecTestTransport(socket)
        let service = ExecService(transports: { _ in transport }, bridges: bridges)
        let capture = ExecStateCapture()
        let run = try execRun(service: service, capture: capture)
        defer { run.cancel() }
        await bridge.incoming.yield(.data(Data([3, 4])))
        await bridge.incoming.yield(.resize(.init(columns: 120, rows: 40)))
        await bridge.incoming.yield(.closeInput)
        try await transportEventually { await bridge.initialCalls == 1 }
        #expect(socket.sent.isEmpty)
        #expect(capture.endpoints.count == 1)
        await initial.open()
        try await transportEventually { socket.sent.count == 4 }
        let frames = try socket.sent.map { try RemoteCommandFrame(data: $0) }
        #expect(frames == [.resize(.init(columns: 80, rows: 24)), .stdin(Data([3, 4])), .resize(.init(columns: 120, rows: 40)), .close(.stdin)])
        #expect(socket.sent.last == Data([255, 0]))
        await socket.incoming.yield(Data([1, 65]))
        await socket.incoming.yield(Data([2, 66]))
        await socket.incoming.yield(execStatus(#"{"status":"Failure","reason":"NonZeroExitCode","details":{"causes":[{"reason":"ExitCode","message":"37"}]}}"#))
        try await transportEventually { await bridge.sending == 1 }
        #expect(await bridge.sent.isEmpty)
        #expect(capture.states == [.running])
        await output.open()
        #expect(await run.value == .exited(code: 37))
        #expect(await bridge.sent == [.data(Data([65])), .data(Data([66])), .exit(code: 37)])
        #expect(await bridge.maximumWriters == 1)
        #expect(await bridge.closes == 1)
        #expect(socket.isCancelled)
        #expect(await bridge.incoming.waiting == false)
        #expect(await socket.incoming.waiting == false)
        let request = try #require(await transport.requests.first)
        let url = try request.urlRequest(baseURL: URL(string: "https://synthetic.invalid")!, purpose: .webSocket).url!
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(.init(name: "tty", value: "true")))
        #expect(query.contains(.init(name: "stderr", value: "false")))
        #expect(query.filter { $0.name == "command" }.compactMap(\.value).prefix(3) == ["env", "TERM=xterm-256color", "sh"])
    }

    @Test func largeOutputIsSplitWithoutInterleavingBeforeSuccess() async throws {
        let bridge = try ExecTestBridge()
        let socket = ExecTestSocket()
        let transport = ExecTestTransport(socket)
        let service = ExecService(transports: { _ in transport }, bridges: ExecTestBridges(bridge))
        let run = try execRun(service: service, capture: ExecStateCapture())
        defer { run.cancel() }
        let bytes = Data(repeating: 0x5a, count: 150_000)
        await socket.incoming.yield(Data([1]) + bytes)
        await socket.incoming.yield(Data([255, 1]))
        await socket.incoming.yield(Data([255, 2]))
        await socket.incoming.yield(execStatus())
        #expect(await run.value == .exited(code: 0))
        let frames = await bridge.sent
        let chunks = frames.compactMap { if case .data(let data) = $0 { return data }; return nil }
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.count <= BridgeFrame.maximumDataByteCount })
        #expect(chunks.reduce(Data(), +) == bytes)
        #expect(frames.last == .exit(code: 0))
    }

    @Test(arguments: [
        #"{"status":"Failure","reason":"InternalError","message":"Synthetic server failure"}"#,
        #"{"status":"Failure","reason":"NotFound","message":"Pod deleted"}"#,
        #"{"status":"Failure","reason":"Forbidden","message":"pods/exec denied"}"#,
    ])
    func postUpgradeServerFailureRemainsAuthoritative(status: String) async throws {
        let bridge = try ExecTestBridge()
        let socket = ExecTestSocket()
        let transport = ExecTestTransport(socket)
        let service = ExecService(transports: { _ in transport }, bridges: ExecTestBridges(bridge))
        let capture = ExecStateCapture()
        let id = UUID()
        let run = try execRun(service: service, id: id, capture: capture)
        defer { run.cancel() }
        await socket.incoming.yield(Data([1, 65]))
        await socket.incoming.yield(execStatus(status))
        let decoded = try JSONDecoder().decode(KubernetesStatus.self, from: Data(status.utf8))
        let expected = ExecSessionResult.failed(.remote(decoded))
        #expect(await run.value == expected)
        await service.childTerminated(sessionID: id)
        run.cancel()
        #expect(capture.states.last == .finished(expected))
        #expect(await bridge.sent == [.data(Data([65])), .failure(.session)])
    }

    @Test(arguments: [Data([3]), execStatus("not json"), execStatus(#"{"status":"Failure","reason":"NonZeroExitCode"}"#), Data([8]), Data([0, 65]), Data([255, 4])])
    func malformedOrWrongDirectionRemoteFramesFail(frame: Data) async throws {
        let bridge = try ExecTestBridge()
        let socket = ExecTestSocket()
        let transport = ExecTestTransport(socket)
        let service = ExecService(transports: { _ in transport }, bridges: ExecTestBridges(bridge))
        let run = try execRun(service: service, capture: ExecStateCapture())
        defer { run.cancel() }
        await socket.incoming.yield(frame)
        #expect(await run.value == .failed(.protocolViolation))
        #expect(await bridge.sent == [.failure(.protocolViolation)])
    }

    @Test(arguments: [TransportFailure.closed, .connection, .pongTimedOut, .nonBinaryMessage])
    func connectionLossWithoutStatusIsNeverExitZero(failure: TransportFailure) async throws {
        let bridge = try ExecTestBridge()
        let socket = ExecTestSocket()
        let transport = ExecTestTransport(socket)
        let service = ExecService(transports: { _ in transport }, bridges: ExecTestBridges(bridge))
        let run = try execRun(service: service, capture: ExecStateCapture())
        defer { run.cancel() }
        await socket.incoming.yield(Data([1, 65]))
        await socket.incoming.finish(APIError.transport(failure))
        #expect(await run.value == .failed(.api(.transport(failure))))
        #expect(await bridge.sent == [.data(Data([65])), .failure(.connection)])
    }

    @Test(arguments: [APIError.http(code: 403, resource: "pods/exec"), .transport(.upgradeTimedOut), .unsupportedProtocol])
    func failedUpgradeDoesNotAllocateListenerOrSurface(error: APIError) async throws {
        let bridge = try ExecTestBridge()
        let bridges = ExecTestBridges(bridge)
        let socket = ExecTestSocket()
        let transport = ExecTestTransport(socket, failure: error)
        let service = ExecService(transports: { _ in transport }, bridges: bridges)
        let capture = ExecStateCapture()
        let run = try execRun(service: service, capture: capture)
        #expect(await run.value == .failed(.api(error)))
        #expect(capture.endpoints.isEmpty)
        #expect(await bridges.prepared.isEmpty)
    }

    @Test func nonV5SocketIsCancelledBeforeBridgeAllocation() async throws {
        let bridge = try ExecTestBridge()
        let bridges = ExecTestBridges(bridge)
        let socket = ExecTestSocket(protocolName: "v4.channel.k8s.io")
        let transport = ExecTestTransport(socket)
        let service = ExecService(transports: { _ in transport }, bridges: bridges)
        let run = try execRun(service: service, capture: ExecStateCapture())
        #expect(await run.value == .failed(.api(.unsupportedProtocol)))
        #expect(socket.isCancelled)
        #expect(await bridges.prepared.isEmpty)
    }
}

@Suite @MainActor struct ExecLifecycleTests {
    @Test func handshakeFailureClosesOwnedBridgeAndSocket() async throws {
        let bridge = try ExecTestBridge(initialFailure: BridgeProtocolError.invalidNonce)
        let socket = ExecTestSocket()
        let transport = ExecTestTransport(socket)
        let service = ExecService(transports: { _ in transport }, bridges: ExecTestBridges(bridge))
        let run = try execRun(service: service, capture: ExecStateCapture())
        #expect(await run.value == .failed(.protocolViolation))
        #expect(await bridge.closes == 1)
        #expect(socket.isCancelled)
        #expect(socket.sent.isEmpty)
    }

    @Test func surfaceFailureReleasesListenerWithoutWaitingForChild() async throws {
        let bridge = try ExecTestBridge()
        let socket = ExecTestSocket()
        let transport = ExecTestTransport(socket)
        let service = ExecService(transports: { _ in transport }, bridges: ExecTestBridges(bridge))
        let result = await service.run(
            sessionID: UUID(), target: try execTarget(), ready: { _ in throw ExecFailure.surface }, update: { _ in }
        )
        #expect(result == .failed(.surface))
        #expect(await bridge.initialCalls == 0)
        #expect(await bridge.closes == 1)
        #expect(socket.isCancelled)
    }

    @Test(arguments: [true, false])
    func childFirstDeathDuringHandshakeOrRelayFailsWithoutFabricatedExit(handshaking: Bool) async throws {
        let bridge = try ExecTestBridge(initialGate: handshaking ? TestGate() : nil)
        let socket = ExecTestSocket()
        let transport = ExecTestTransport(socket)
        let service = ExecService(transports: { _ in transport }, bridges: ExecTestBridges(bridge))
        let id = UUID()
        let run = try execRun(service: service, id: id, capture: ExecStateCapture())
        defer { run.cancel() }
        try await transportEventually { await bridge.initialCalls == 1 }
        if !handshaking { try await transportEventually { await bridge.incoming.waiting } }
        await service.childTerminated(sessionID: id)
        #expect(await run.value == .failed(.childTerminated))
        #expect(await bridge.closes == 1)
        #expect(socket.isCancelled)
    }

    @Test func socketEOFIsDetectedEvenWithoutGhosttyCallback() async throws {
        let bridge = try ExecTestBridge()
        let socket = ExecTestSocket()
        let transport = ExecTestTransport(socket)
        let service = ExecService(transports: { _ in transport }, bridges: ExecTestBridges(bridge))
        let run = try execRun(service: service, capture: ExecStateCapture())
        defer { run.cancel() }
        await bridge.incoming.finish(ExecFailure.childTerminated)
        #expect(await run.value == .failed(.childTerminated))
        #expect(await bridge.closes == 1)
    }

    @Test(arguments: ["upgrade", "handshake", "resize", "relay"])
    func cancellationJoinsBlockedOperationsAndCanBeRepeated(phase: String) async throws {
        let bridge = try ExecTestBridge(initialGate: phase == "handshake" ? TestGate() : nil)
        let socket = ExecTestSocket(sendGate: phase == "resize" ? TestGate() : nil)
        let transport = ExecTestTransport(socket, upgradeGate: phase == "upgrade" ? TestGate() : nil)
        let bridges = ExecTestBridges(bridge)
        let service = ExecService(transports: { _ in transport }, bridges: bridges)
        let run = try execRun(service: service, capture: ExecStateCapture())
        if phase == "upgrade" { try await transportEventually { await transport.requests.count == 1 } }
        if phase == "handshake" { try await transportEventually { await bridge.initialCalls == 1 } }
        if phase == "resize" { try await transportEventually { socket.sent.count == 1 } }
        if phase == "relay" { try await transportEventually { await socket.incoming.waiting } }
        run.cancel()
        run.cancel()
        #expect(await run.value == .cancelled)
        if phase != "upgrade" {
            #expect(socket.isCancelled)
            #expect(await bridge.closes == 1)
        } else {
            #expect(await bridges.prepared.isEmpty)
        }
        #expect(await bridge.incoming.waiting == false)
        #expect(await socket.incoming.waiting == false)
    }

    @Test func blockedLocalOutputTimesOutWithoutConsumingUnboundedRemoteOutput() async throws {
        let clock = ManualTransportClock()
        let bridge = try ExecTestBridge(outputGate: TestGate())
        let socket = ExecTestSocket()
        let transport = ExecTestTransport(socket)
        let service = ExecService(transports: { _ in transport }, bridges: ExecTestBridges(bridge), clock: clock)
        let run = try execRun(service: service, capture: ExecStateCapture())
        defer { run.cancel() }
        await socket.incoming.yield(Data([1, 65]))
        await socket.incoming.yield(execStatus())
        try await transportEventually { clock.deadlines.contains(2) }
        clock.advance(to: 2)
        #expect(await run.value == .failed(.api(.transport(.timedOut))))
        #expect(await bridge.sent == [.failure(.connection)])
        #expect(await bridge.closes == 1)
        #expect(clock.deadlines.isEmpty)
    }
}
