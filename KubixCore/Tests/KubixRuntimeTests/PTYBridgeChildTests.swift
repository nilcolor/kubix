import Darwin
import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Suite struct PTYBridgeChildTests {
    @Test func singleCharacterControlBytesNoEchoAndOutputWithoutTranslation() throws {
        let session = try BridgeTestSession()
        let flags = bridgeStatusFlags(session.tty.terminal)
        let run = session.start()
        defer { session.stop() }
        try session.handshake()
        for byte: UInt8 in [0x78, 3, 4, 13, 10, 0, 0xff] {
            try bridgeWrite(session.inputWriter, bytes: Data([byte]))
            #expect(try session.nextFrame() == .data(Data([byte])))
        }
        // Input was received by the server, yet there are no echoed bytes at the PTY master.
        #expect(try BridgeIO.read(session.tty.controller, maximumCount: 100) == nil)
        let output = Data([10, 13, 0, 3, 4, 0xff, 0x61])
        try session.send(.data(output))
        try session.send(.exit(code: 42))
        #expect(try bridgeRead(session.outputReader, count: output.count) == output)
        #expect(try run.wait() == .remoteExit(42))
        #expect(run.diagnostic.isEmpty)
        #expect(try PTYSnapshot(session.tty.terminal) == session.tty.original)
        #expect(bridgeStatusFlags(session.tty.terminal) == flags)
        #expect(try BridgeIO.read(session.connector.peer, maximumCount: 1) == Data())
    }

    @Test func prequeuedInputFollowsHelloAndInitialSizeWithPartialIOAndEINTR() throws {
        let session = try BridgeTestSession(inputPipe: true, chunk: 1, interrupt: true)
        let payload = Data("queued before raw setup".utf8)
        try bridgeWrite(session.inputWriter, bytes: payload)
        let run = session.start()
        defer { session.stop() }
        try session.handshake()
        #expect(try session.nextFrame() == .data(payload))
        let output = Data("split reply\n".utf8)
        try session.send(.data(output))
        try session.send(.exit(code: 0))
        #expect(try bridgeRead(session.outputReader, count: output.count) == output)
        #expect(try run.wait() == .remoteExit(0))
    }

    @Test func resizeAndInputShareAnUncorruptedSerializedWriter() throws {
        let session = try BridgeTestSession(inputPipe: true, chunk: 7, interrupt: true)
        let run = session.start()
        defer { session.stop() }
        try session.handshake()
        try session.tty.resize(columns: 143, rows: 39)
        let payload = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0) })
        let writers = DispatchGroup()
        writers.enter()
        DispatchQueue(label: "kubix.test.resize").async {
            for _ in 0..<500 { run.control.resize() }
            writers.leave()
        }
        try bridgeWrite(session.inputWriter, bytes: payload)
        var received = Data()
        var resized = false
        while received.count < payload.count || !resized {
            switch try session.nextFrame() {
            case .data(let bytes): received.append(bytes)
            case .resize(let size):
                #expect(size == BridgeSize(columns: 143, rows: 39))
                resized = true
            default: Issue.record("Unexpected or interleaved relay frame")
            }
        }
        #expect(writers.wait(timeout: .now() + 5) == .success)
        #expect(received == payload)
        try session.send(.exit(code: 0))
        #expect(try run.wait() == .remoteExit(0))
    }

    @Test func inputEOFSendsOnlyHalfCloseAndStillReadsOutputAndResize() throws {
        let session = try BridgeTestSession(inputPipe: true)
        let run = session.start()
        defer { session.stop() }
        try session.handshake()
        session.inputPipe?.closeWriter()
        #expect(try session.nextFrame() == .closeInput)
        #expect(!run.finished)
        try session.tty.resize(columns: 90, rows: 30)
        run.control.resize()
        #expect(try session.nextFrame() == .resize(BridgeSize(columns: 90, rows: 30)))
        let output = Data("output after stdin EOF\n".utf8)
        try session.send(.data(output))
        try session.send(.exit(code: 7))
        #expect(try bridgeRead(session.outputReader, count: output.count) == output)
        #expect(try run.wait() == .remoteExit(7))
    }

    @Test(arguments: BridgeFailure.allCases)
    func genericFailureDrainsOutputAndReportsOnlyAfterRestoration(failure: BridgeFailure) throws {
        let session = try BridgeTestSession()
        let run = session.start()
        defer { session.stop() }
        try session.handshake()
        let output = Data("preceding output\n".utf8)
        try bridgeWrite(session.connector.peer, bytes: BridgeFrame.data(output).encoded() + BridgeFrame.failure(failure).encoded())
        #expect(try bridgeRead(session.outputReader, count: output.count) == output)
        let result = try run.wait()
        #expect(result == .localFailure(failure))
        #expect(result.exitStatus != 0)
        #expect(run.diagnostic == "kubix: \(failure.rawValue)\n")
        #expect(run.diagnostic.utf8.count <= BridgeFrame.maximumFailureByteCount + 8)
        #expect(run.diagnosticAfterRestoration)
    }

    @Test(arguments: [Data(), Data([2, 0, 0]), Data([2, 0, 0, 0, 5, 1])])
    func socketEOFWithoutTerminalFrameIsTransportFailure(tail: Data) throws {
        let session = try BridgeTestSession()
        let run = session.start()
        defer { session.stop() }
        try session.handshake()
        let output = Data("before disconnected socket\n".utf8)
        try bridgeWrite(session.connector.peer, bytes: BridgeFrame.data(output).encoded() + tail)
        #expect(shutdown(session.connector.peer, SHUT_WR) == 0)
        #expect(try bridgeRead(session.outputReader, count: output.count) == output)
        #expect(try run.wait() == .localFailure(.connection))
        #expect(run.diagnosticAfterRestoration)
    }

    @Test(arguments: [
        Data([99, 0, 0, 0, 0]), Data([2, 255, 255, 255, 255]),
        try! BridgeFrame.closeInput.encoded(),
        Data([6, 0, 0, 0, 13]) + Data("secret-output".utf8),
    ])
    func malformedParentFrameCannotErasePriorOutputOrLeakItsPayload(tail: Data) throws {
        let session = try BridgeTestSession()
        let run = session.start()
        defer { session.stop() }
        try session.handshake()
        let output = Data("accepted before malformed frame\n".utf8)
        try bridgeWrite(session.connector.peer, bytes: BridgeFrame.data(output).encoded() + tail)
        #expect(try bridgeRead(session.outputReader, count: output.count) == output)
        #expect(try run.wait() == .localFailure(.protocolViolation))
        #expect(run.diagnosticAfterRestoration)
        #expect(!run.diagnostic.contains("secret-output"))
        #expect(!run.diagnostic.contains(session.nonce.environmentValue))
    }

    @Test func stalledSocketWriterDoesNotPreventOutputOrRemoteExit() throws {
        let session = try BridgeTestSession(inputPipe: true, stallAfterHandshake: true)
        let run = session.start()
        defer { session.stop() }
        try session.handshake()
        try bridgeWrite(session.inputWriter, bytes: Data(repeating: 65, count: 4_096))
        let output = Data("independent output pump\n".utf8)
        try session.send(.data(output))
        try session.send(.exit(code: 17))
        #expect(try bridgeRead(session.outputReader, count: output.count) == output)
        #expect(try run.wait() == .remoteExit(17))
    }

    @Test func realSocketBackpressureDoesNotBlockTheOutputPumpOrExit() throws {
        let session = try BridgeTestSession(inputPipe: true)
        while try BridgeIO.write(session.inputWriter, bytes: Data(repeating: 65, count: 4_096)) > 0 {}
        let run = session.start()
        defer { session.stop() }
        try session.handshake()
        try bridgeEventually { session.connector.encounteredBackpressure }
        let output = Data("output while the peer refuses input\n".utf8)
        try session.send(.data(output))
        try session.send(.exit(code: 42))
        #expect(try bridgeRead(session.outputReader, count: output.count) == output)
        #expect(try run.wait(seconds: 1) == .remoteExit(42))
        #expect(try PTYSnapshot(session.tty.terminal) == session.tty.original)
    }

}

@Suite struct PTYBridgeLifecycleTests {
    @Test func concurrentResizeInputExitAndCancellationHaveOneOwnerAndRestoreEveryTime() throws {
        for _ in 0..<20 {
            let session = try BridgeTestSession(inputPipe: true, chunk: 11)
            let run = session.start()
            defer { session.stop() }
            try session.handshake()
            try bridgeWrite(session.inputWriter, bytes: Data(repeating: 3, count: 2_048))
            let callbacks = DispatchGroup()
            callbacks.enter()
            DispatchQueue(label: "kubix.test.teardown").async {
                for _ in 0..<100 { run.control.resize() }
                run.control.cancel()
                callbacks.leave()
            }
            // Either event may win; neither can close another worker's descriptors.
            let sentExit = (try? session.send(.exit(code: 7))) != nil
            let result = try run.wait(seconds: 1)
            #expect(result == .remoteExit(7) || result == .localFailure(.cancelled))
            if !sentExit { #expect(result == .localFailure(.cancelled)) }
            #expect(callbacks.wait(timeout: .now() + 5) == .success)
            #expect(try PTYSnapshot(session.tty.terminal) == session.tty.original)
            #expect(fcntl(session.input, F_GETFD) >= 0 && fcntl(session.output, F_GETFD) >= 0)
        }
    }

    @Test func idleCancellationRestoresAndClosesOwnedSocketWithoutClosingCallerFDs() throws {
        let session = try BridgeTestSession()
        let run = session.start()
        defer { session.stop() }
        try session.handshake()
        run.control.cancel()
        #expect(try run.wait(seconds: 1) == .localFailure(.cancelled))
        #expect(run.diagnosticAfterRestoration)
        #expect(fcntl(session.tty.terminal, F_GETFD) >= 0)
        #expect(try BridgeIO.read(session.connector.peer, maximumCount: 1) == Data())
        // Late notifications have no descriptor to close, including after the worker returned.
        run.control.resize()
        run.control.cancel()
        let probe = try TestBridgePipe()
        try bridgeWrite(probe.writer, bytes: Data([42]))
        #expect(try bridgeRead(probe.reader, count: 1) == Data([42]))
    }

    @Test func blockedOutputStillAcceptsInputAndCancellationHasBoundedDrain() throws {
        let session = try BridgeTestSession(inputPipe: true, outputPipe: true)
        while try BridgeIO.write(session.output, bytes: Data(repeating: 0, count: 4_096)) > 0 {}
        let run = session.start()
        defer { session.stop() }
        try session.handshake()
        try session.send(.data(Data(repeating: 10, count: BridgeFrame.maximumDataByteCount)))
        try bridgeEventually { session.connector.bytesRead == BridgeFrame.maximumDataByteCount + BridgeFrame.headerByteCount }
        // A round-trip input frame is a barrier while the output consumer deliberately reads nothing.
        try bridgeWrite(session.inputWriter, bytes: Data([3]))
        #expect(try session.nextFrame() == .data(Data([3])))
        for _ in 0..<100 { run.control.resize() }
        run.control.cancel()
        #expect(try run.wait(seconds: 3) == .localFailure(.cancelled))
        #expect(run.diagnosticAfterRestoration)
    }

    @Test(arguments: [BridgeFrame.exit(code: 19), BridgeFrame.failure(.session)])
    func terminalFrameWaitsForAllBackpressuredOutput(final: BridgeFrame) throws {
        let session = try BridgeTestSession(outputPipe: true)
        var prefixCount = 0
        while true {
            let count = try BridgeIO.write(session.output, bytes: Data(repeating: 0, count: 4_096))
            if count == 0 { break }
            prefixCount += count
        }
        let run = session.start()
        defer { session.stop() }
        try session.handshake()
        let payload = Data(repeating: 10, count: BridgeFrame.maximumDataByteCount)
        try bridgeWrite(session.connector.peer, bytes: BridgeFrame.data(payload).encoded() + final.encoded())
        try bridgeEventually { session.connector.bytesRead == payload.count + BridgeFrame.headerByteCount }
        #expect(!run.finished)
        let output = try bridgeRead(session.outputReader, count: prefixCount + payload.count)
        #expect(output == Data(repeating: 0, count: prefixCount) + payload)
        let result = try run.wait()
        if case .exit(let code) = final {
            #expect(result == .remoteExit(code))
        } else {
            #expect(result == .localFailure(.session))
            #expect(run.diagnosticAfterRestoration)
        }
    }

    @Test func invalidEnvironmentAndPrecancelledStartNeverConnectOrChangeTTY() throws {
        let session = try BridgeTestSession()
        let child = PTYBridgeChild(connector: session.connector)
        let environments: [[String: String]] = [
            [:], ["KUBIX_BRIDGE_SOCK": "/safe/socket"], ["KUBIX_BRIDGE_NONCE": session.nonce.environmentValue],
            ["KUBIX_BRIDGE_SOCK": "/safe/socket", "KUBIX_BRIDGE_NONCE": "secret-invalid-nonce"],
            ["KUBIX_BRIDGE_SOCK": "/unsafe/../socket", "KUBIX_BRIDGE_NONCE": session.nonce.environmentValue],
        ]
        for environment in environments {
            var diagnostic = ""
            let result = child.run(environment: environment, input: session.input, output: session.output) { diagnostic = $0 }
            #expect(result == .localFailure(.connection))
            #expect(diagnostic == "kubix: The terminal connection failed.\n")
            #expect(try PTYSnapshot(session.tty.terminal) == session.tty.original)
        }
        let control = PTYBridgeControl()
        control.cancel()
        #expect(child.run(environment: session.environment, input: session.input, output: session.output, control: control, diagnostic: { _ in })
            == .localFailure(.cancelled))
        #expect(session.connector.connectionCount == 0)
    }
}
