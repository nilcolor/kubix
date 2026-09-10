import Darwin
import Foundation
import KubixCore

enum PTYBridgeResult: Equatable, Sendable {
    case remoteExit(UInt8)
    case localFailure(BridgeFailure)

    var exitStatus: Int32 {
        switch self {
        case .remoteExit(let code): Int32(code)
        case .localFailure: EX_IOERR
        }
    }
}

public struct PTYBridgeChild: Sendable {
    let connector: any BridgeConnecting
    let clock: any TransportClock

    init(connector: any BridgeConnecting = UnixBridgeConnector(), clock: any TransportClock = ContinuousTransportClock()) {
        self.connector = connector
        self.clock = clock
    }

    /// Synchronous pre-application entry. No app singleton, credential service, run loop, or
    /// process launcher is needed. All worker-owned resources are gone before returning.
    public static func main(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        let control = PTYBridgeControl()
        do {
            let signals = try PTYBridgeSignals(control: control)
            return withExtendedLifetime(signals) {
                PTYBridgeChild().run(environment: environment, control: control).exitStatus
            }
        } catch {
            PTYBridgeDiagnostic.write("kubix: The terminal connection failed.\n")
            return EX_IOERR
        }
    }

    func run(
        environment: [String: String], input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO,
        terminal: Int32? = nil, control: PTYBridgeControl = PTYBridgeControl(),
        diagnostic: (String) -> Void = { PTYBridgeDiagnostic.write($0) }
    ) -> PTYBridgeResult {
        let result: PTYBridgeResult
        do {
            result = try relay(environment: environment, input: input, output: output, terminal: terminal ?? input, control: control)
        } catch is CancellationError {
            result = .localFailure(.cancelled)
        } catch {
            result = .localFailure(.connection)
        }
        if case .localFailure(let failure) = result {
            diagnostic("kubix: \(failure.rawValue)\n")
        }
        return result
    }

    private func relay(
        environment: [String: String], input: Int32, output: Int32, terminal: Int32, control: PTYBridgeControl
    ) throws -> PTYBridgeResult {
        guard let path = environment["KUBIX_BRIDGE_SOCK"], let value = environment["KUBIX_BRIDGE_NONCE"] else {
            throw BridgeIOError.unavailable
        }
        try BridgeSocketPath.validate(path)
        let nonce = try BridgeNonce(environmentValue: value)
        guard !control.isCancelled else { throw CancellationError() }
        let tty = try PTYTerminal(descriptor: terminal)
        let descriptors = try PTYBridgeDescriptors(input: input, output: output)
        try descriptors.prepare()
        let connection = try connector.connect(path: path, control: control, clock: clock)
        defer { connection.close() }
        do {
            try tty.makeRaw()
            let hello = try BridgeFrame.hello(nonce).encoded() + BridgeFrame.resize(tty.size()).encoded()
            var pump = PTYBridgePump(connection: connection, terminal: tty, descriptors: descriptors, clock: clock, outgoing: hello)
            let result = pump.run(control: control)
            try tty.restore()
            return result
        } catch {
            try tty.restore()
            throw error
        }
    }
}

/// Two independently serviced nonblocking pumps, one serialized socket writer. No unbounded
/// queues/tasks: at most one 4KiB input frame, one 64KiB output frame, and one coalesced resize.
/// Poll never exceeds 20ms, including blocked stdout/socket, so cancellation needs no cross-
/// thread close/shutdown and cannot race reused descriptors.
private struct PTYBridgePump {
    let connection: any BridgeConnection
    let terminal: PTYTerminal
    let descriptors: PTYBridgeDescriptors
    let clock: any TransportClock
    var outgoing: Data
    private var stdout = Data()
    private var decoder = BridgeDecoder()
    private var inputClosed = false
    private var result: PTYBridgeResult?
    private var drainDeadline: TimeInterval?

    init(
        connection: any BridgeConnection, terminal: PTYTerminal, descriptors: PTYBridgeDescriptors,
        clock: any TransportClock, outgoing: Data
    ) {
        self.connection = connection
        self.terminal = terminal
        self.descriptors = descriptors
        self.clock = clock
        self.outgoing = outgoing
    }

    mutating func run(control: PTYBridgeControl) -> PTYBridgeResult {
        while true {
            if control.isCancelled { finish(.localFailure(.cancelled)) }
            do {
                // Reading output never waits for input or the socket writer.
                if result == nil && stdout.isEmpty { try receive() }
                try flushOutput()
                if result == nil { try send(control: control) }
            } catch is BridgeProtocolError {
                finish(.localFailure(.protocolViolation))
            } catch {
                finish(.localFailure(.connection))
            }
            if let completed = drainedResult { return completed }
            wait()
        }
    }

    private var drainedResult: PTYBridgeResult? {
        guard let result else { return nil }
        if stdout.isEmpty { return result }
        guard clock.now >= (drainDeadline ?? clock.now) else { return nil }
        if case .localFailure = result { return result }
        return .localFailure(.connection)
    }

    private mutating func finish(_ outcome: PTYBridgeResult) {
        guard result == nil else { return }
        result = outcome
        drainDeadline = clock.now + 2
        outgoing = Data()
    }

    private mutating func flushOutput() throws {
        guard !stdout.isEmpty else { return }
        do {
            stdout.removeFirst(try BridgeIO.write(descriptors.output, bytes: stdout))
        } catch {
            // A permanently broken output cannot be drained. Do not spin until the deadline
            // or report a remote exit when stdout has rejected its preceding bytes.
            stdout = Data()
            result = .localFailure(.connection)
            throw error
        }
    }

    private mutating func receive() throws {
        // Never decode beyond a frame boundary: a malformed later frame cannot erase data
        // accepted before it (BridgeDecoder.append intentionally fails an entire call).
        guard let bytes = try connection.read(maximumCount: min(4_096, decoder.bytesNeededForFrame)) else { return }
        guard !bytes.isEmpty else {
            try? decoder.finish()
            finish(.localFailure(.connection))
            return
        }
        for frame in try decoder.append(bytes) {
            switch frame {
            case .data(let bytes): stdout = bytes
            case .exit(let code): finish(.remoteExit(code))
            case .failure(let failure): finish(.localFailure(failure))
            default: throw BridgeProtocolError.unexpectedFrame
            }
        }
    }

    private mutating func send(control: PTYBridgeControl) throws {
        if outgoing.isEmpty {
            if control.takeResize() {
                outgoing = try BridgeFrame.resize(terminal.size()).encoded()
            }
            if !inputClosed, let bytes = try BridgeIO.read(descriptors.input, maximumCount: 4_096) {
                if bytes.isEmpty {
                    inputClosed = true
                    outgoing += try BridgeFrame.closeInput.encoded()
                } else {
                    outgoing += try BridgeFrame.data(bytes).encoded()
                }
            }
        }
        if !outgoing.isEmpty { outgoing.removeFirst(try connection.write(outgoing)) }
    }

    private func wait() {
        var fds = [
            pollfd(fd: result == nil && socketEvents != 0 ? connection.descriptor : -1, events: socketEvents, revents: 0),
            pollfd(fd: result == nil && outgoing.isEmpty && !inputClosed ? descriptors.input : -1, events: Int16(POLLIN), revents: 0),
            pollfd(fd: stdout.isEmpty ? -1 : descriptors.output, events: Int16(POLLOUT), revents: 0),
        ]
        _ = Darwin.poll(&fds, nfds_t(fds.count), 20)
    }

    private var socketEvents: Int16 {
        (stdout.isEmpty ? Int16(POLLIN) : 0) | (outgoing.isEmpty ? 0 : Int16(POLLOUT))
    }
}
