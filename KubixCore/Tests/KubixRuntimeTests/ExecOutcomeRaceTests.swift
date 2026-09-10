import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Suite @MainActor struct ExecOutcomeRaceTests {
    @Test(arguments: [false, true])
    func childCallbackAndCancellationDuringTerminalDrainCannotOverwriteOutcome(failure: Bool) async throws {
        let gate = TestGate()
        let bridge = try ExecTestBridge(terminalGate: gate)
        let socket = ExecTestSocket()
        let transport = ExecTestTransport(socket)
        let service = ExecService(transports: { _ in transport }, bridges: ExecTestBridges(bridge))
        let capture = ExecStateCapture()
        let id = UUID()
        let run = try execRun(service: service, id: id, capture: capture)
        defer { run.cancel() }
        let status = failure ? #"{"status":"Failure","reason":"InternalError","message":"Synthetic failure"}"# : #"{"status":"Success"}"#
        await socket.incoming.yield(execStatus(status))
        try await transportEventually { await bridge.sending == 1 }
        let expected = failure
            ? ExecSessionResult.failed(.remote(try JSONDecoder().decode(KubernetesStatus.self, from: Data(status.utf8))))
            : .exited(code: 0)
        #expect(capture.states.last == .finished(expected))
        await service.childTerminated(sessionID: id)
        run.cancel()
        await gate.open()
        #expect(await run.value == expected)
        #expect(await bridge.sent == [failure ? .failure(.session) : .exit(code: 0)])
        #expect(await bridge.closes == 1)
    }

    @Test func remoteOutcomeCancelsBlockedInputWriteButStillDeliversFinalOutput() async throws {
        let bridge = try ExecTestBridge()
        let socket = ExecTestSocket(sendGate: TestGate(), blockAfter: 1)
        let transport = ExecTestTransport(socket)
        let service = ExecService(transports: { _ in transport }, bridges: ExecTestBridges(bridge))
        let run = try execRun(service: service, capture: ExecStateCapture())
        defer { run.cancel() }
        await bridge.incoming.yield(.data(Data([3])))
        try await transportEventually { socket.sent.count == 2 }
        await socket.incoming.yield(Data([1, 65]))
        await socket.incoming.yield(execStatus())
        #expect(await run.value == .exited(code: 0))
        #expect(await bridge.sent == [.data(Data([65])), .exit(code: 0)])
        #expect(socket.isCancelled)
        #expect(await bridge.incoming.waiting == false)
    }

    @Test func failedTerminalDrainIsBoundedAndRetainsAuthoritativeDiagnostic() async throws {
        let clock = ManualTransportClock()
        let bridge = try ExecTestBridge(terminalGate: TestGate())
        let socket = ExecTestSocket()
        let transport = ExecTestTransport(socket)
        let service = ExecService(transports: { _ in transport }, bridges: ExecTestBridges(bridge), clock: clock)
        let run = try execRun(service: service, capture: ExecStateCapture())
        defer { run.cancel() }
        await socket.incoming.yield(Data([3]))
        try await transportEventually { clock.deadlines.contains(2) }
        clock.advance(to: 2)
        #expect(await run.value == .failed(.protocolViolation))
        #expect(await bridge.sent.isEmpty)
        #expect(await bridge.closes == 1)
        #expect(clock.deadlines.isEmpty)
    }

    @Test func unsolicitedTransportCancellationIsAFailureRatherThanUserCancellation() async throws {
        let bridge = try ExecTestBridge()
        let socket = ExecTestSocket()
        let transport = ExecTestTransport(socket)
        let service = ExecService(transports: { _ in transport }, bridges: ExecTestBridges(bridge))
        let run = try execRun(service: service, capture: ExecStateCapture())
        defer { run.cancel() }
        await socket.incoming.finish(CancellationError())
        #expect(await run.value == .failed(.api(.transport(.connection))))
        #expect(await bridge.sent == [.failure(.connection)])
    }
}
