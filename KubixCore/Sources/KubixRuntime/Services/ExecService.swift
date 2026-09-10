import Foundation
import KubixCore

/// The factory must return the existing authenticated per-context transport, not a bare URL socket.
public actor ExecService: ExecSessionControlling {
    public typealias TransportFactory = @Sendable (ResolvedContext) async throws -> any Transport
    private let transports: TransportFactory
    private let bridges: any PTYBridgeServing
    private let clock: any TransportClock
    private var readOnlyValidation = false
    private var sessions: [UUID: ExecRunControl] = [:]

    public init(transports: @escaping TransportFactory, bridgeServer: PTYBridgeServer = PTYBridgeServer()) {
        self.transports = transports
        bridges = bridgeServer
        clock = ContinuousTransportClock()
    }

    #if DEBUG
    public init(transports: @escaping TransportFactory, validationRoot: URL) {
        self.transports = transports
        bridges = PTYBridgeServer(validationRoot: validationRoot)
        clock = ContinuousTransportClock()
        readOnlyValidation = true
    }
    #endif

    init(
        transports: @escaping TransportFactory, bridges: any PTYBridgeServing,
        clock: any TransportClock = ContinuousTransportClock()
    ) {
        self.transports = transports
        self.bridges = bridges
        self.clock = clock
    }

    public func run(
        sessionID: UUID, target: ExecTarget,
        ready: @escaping @MainActor @Sendable (ExecBridgeEndpoint) throws -> Void,
        update: @escaping @MainActor @Sendable (ExecSession.State) -> Void
    ) async -> ExecSessionResult {
        guard sessions[sessionID] == nil else { return .failed(.bridge) }
        let control = ExecRunControl()
        sessions[sessionID] = control
        let invocation = ExecInvocation(
            sessionID: sessionID, target: target, ready: ready, update: update, readOnlyValidation: readOnlyValidation
        )
        let worker = Task { [transports, bridges, clock] in
            await Self.execute(
                invocation, transports: transports, bridges: bridges, clock: clock, control: control
            )
        }
        control.install(worker)
        let result = await withTaskCancellationHandler {
            if Task.isCancelled { control.stop(.cancelled) }
            return await worker.value
        } onCancel: { control.stop(.cancelled) }
        sessions.removeValue(forKey: sessionID)
        return result
    }

    public func childTerminated(sessionID: UUID) {
        sessions[sessionID]?.stop(.failed(.childTerminated))
    }

    private static func execute(
        _ invocation: ExecInvocation, transports: TransportFactory, bridges: any PTYBridgeServing,
        clock: any TransportClock, control: ExecRunControl
    ) async -> ExecSessionResult {
        var socket: (any WebSocketConnection)?
        var bridge: (any PTYBridgeSession)?
        var fallback = ExecFailure.api(.transport(.connection))
        do {
            try Task.checkCancellation()
            let transport = try await transports(invocation.target.context)
            try Task.checkCancellation()
            let request = try shellRequest(invocation.target, readOnlyValidation: invocation.readOnlyValidation)
            let connection = try await transport.webSocket(for: request.apiRequest)
            socket = connection
            guard connection.negotiatedProtocol == URLSessionTransport.execProtocol else { throw APIError.unsupportedProtocol }
            try Task.checkCancellation()
            fallback = .bridge
            let terminal = try await bridges.prepare(sessionID: invocation.sessionID)
            bridge = terminal
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await invocation.ready(terminal.endpoint)
                let size = try await terminal.initialSize()
                try await connection.send(RemoteCommandFrame.resize(.init(columns: size.columns, rows: size.rows)).encoded())
                await invocation.update(.running)
                _ = await pump(socket: connection, bridge: terminal, clock: clock, control: control)
            } onCancel: { connection.cancel() }
        } catch {
            control.finish(result(error, fallback: fallback))
        }
        let result = control.result ?? control.finish(.failed(fallback))
        // Publish first: subsequent Ghostty child callbacks cannot invent a remote exit.
        await invocation.update(.finished(result))
        socket?.cancel()
        if let bridge {
            // Use a fresh, explicitly joined task so cancellation can still send a bounded diagnostic.
            // The caller awaits it; it never outlives session teardown.
            let drain = Task {
                try? await send(terminalFrame(result), to: bridge, clock: clock)
            }
            await drain.value
            await bridge.close()
        }
        return result
    }

    private struct ExecInvocation: Sendable {
        let sessionID: UUID
        let target: ExecTarget
        let ready: @MainActor @Sendable (ExecBridgeEndpoint) throws -> Void
        let update: @MainActor @Sendable (ExecSession.State) -> Void
        let readOnlyValidation: Bool
    }

    static func shellRequest(_ target: ExecTarget, readOnlyValidation: Bool = false) throws -> ExecRequest {
        var command = ["env", "TERM=xterm-256color", "sh", "-c", "command -v bash >/dev/null && exec bash || exec sh"]
        #if DEBUG
        if readOnlyValidation {
            command = [
                "env", "TERM=xterm-256color", "HISTFILE=", "HISTSIZE=0", "HISTFILESIZE=0", "ENV=", "BASH_ENV=",
                "sh", "-c", "command -v bash >/dev/null && exec bash --noprofile --norc || exec sh"
            ]
        }
        #endif
        return try ExecRequest(
            namespace: target.namespace, pod: target.pod, container: target.container,
            command: command
        )
    }

    private static func pump(
        socket: any WebSocketConnection, bridge: any PTYBridgeSession, clock: any TransportClock, control: ExecRunControl
    ) async -> ExecSessionResult {
        await withTaskGroup(of: ExecSessionResult.self) { group in
            group.addTask {
                do {
                    while true {
                        let frame = try await bridge.receive()
                        let remote: RemoteCommandFrame
                        switch frame {
                        case .data(let bytes): remote = .stdin(bytes)
                        case .resize(let size): remote = .resize(.init(columns: size.columns, rows: size.rows))
                        case .closeInput: remote = .close(.stdin)
                        default: throw BridgeProtocolError.unexpectedFrame
                        }
                        try await socket.send(remote.encoded())
                    }
                } catch { return control.finish(result(error, fallback: .bridge)) }
            }
            group.addTask {
                do {
                    return try await output(socket: socket, bridge: bridge, clock: clock, control: control)
                } catch { return control.finish(result(error, fallback: .api(.transport(.connection)))) }
            }
            let first = await group.next() ?? .cancelled
            let selected = control.finish(first)
            socket.cancel()
            group.cancelAll()
            return selected
        }
    }

    private static func output(
        socket: any WebSocketConnection, bridge: any PTYBridgeSession, clock: any TransportClock, control: ExecRunControl
    ) async throws -> ExecSessionResult {
        var closed: Set<RemoteCommandFrame.Channel> = []
        while true {
            let data = try await socket.receive()
            guard data.count <= 1_048_576 else { throw APIError.transport(.receiveBufferOverflow) }
            switch try RemoteCommandFrame(data: data) {
            case .stdout(let bytes):
                guard !closed.contains(.stdout) else { throw BridgeProtocolError.unexpectedFrame }
                try await outputBytes(bytes, bridge: bridge, clock: clock)
            case .stderr(let bytes):
                guard !closed.contains(.stderr) else { throw BridgeProtocolError.unexpectedFrame }
                try await outputBytes(bytes, bridge: bridge, clock: clock)
            case .error(let status):
                return control.finish(outcome(ExecOutcome(statusData: status)))
            case .close(let channel) where channel == .stdout || channel == .stderr:
                guard closed.insert(channel).inserted else { throw BridgeProtocolError.unexpectedFrame }
            default: throw BridgeProtocolError.unexpectedFrame
            }
        }
    }

    private static func outputBytes(_ bytes: Data, bridge: any PTYBridgeSession, clock: any TransportClock) async throws {
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let end = min(offset + BridgeFrame.maximumDataByteCount, bytes.endIndex)
            try await send(.data(Data(bytes[offset..<end])), to: bridge, clock: clock)
            offset = end
        }
    }

    private static func send(_ frame: BridgeFrame, to bridge: any PTYBridgeSession, clock: any TransportClock) async throws {
        try await withTransportDeadline(until: clock.now + 2, clock: clock) { try await bridge.send(frame) }
    }

    private static func outcome(_ outcome: ExecOutcome) -> ExecSessionResult {
        switch outcome {
        case .remoteExit(let code): .exited(code: code)
        case .remoteFailure(let status): .failed(.remote(status))
        case .protocolFailure: .failed(.protocolViolation)
        case .transportFailure(let failure): .failed(.api(.transport(failure)))
        }
    }

    private static func result(_ error: any Error, fallback: ExecFailure) -> ExecSessionResult {
        if error is CancellationError { return Task.isCancelled ? .cancelled : .failed(fallback) }
        if let error = error as? ExecFailure { return .failed(error) }
        if let error = error as? APIError { return .failed(.api(error)) }
        if error is RemoteCommandProtocolError || error is BridgeProtocolError { return .failed(.protocolViolation) }
        return .failed(fallback)
    }

    private static func terminalFrame(_ result: ExecSessionResult) -> BridgeFrame {
        switch result {
        case .exited(let code): .exit(code: UInt8(code))
        case .cancelled: .failure(.cancelled)
        case .failed(.protocolViolation): .failure(.protocolViolation)
        case .failed(.api): .failure(.connection)
        case .failed: .failure(.session)
        }
    }
}

/// First observed outcome wins, including child-first death while upgrade/handshake is pending.
/// IO task cancellation never overwrites an already-decoded remote status.
private final class ExecRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ExecSessionResult?
    private var worker: Task<ExecSessionResult, Never>?
    var result: ExecSessionResult? { lock.withLock { value } }

    func install(_ worker: Task<ExecSessionResult, Never>) {
        let stopped = lock.withLock {
            self.worker = worker
            return value != nil
        }
        if stopped { worker.cancel() }
    }

    @discardableResult
    func finish(_ result: ExecSessionResult) -> ExecSessionResult {
        lock.withLock {
            if let value { return value }
            value = result
            return result
        }
    }

    func stop(_ result: ExecSessionResult) {
        let pending = lock.withLock {
            guard value == nil else { return Optional<Task<ExecSessionResult, Never>>.none }
            value = result
            return worker
        }
        pending?.cancel()
    }
}
