import Foundation
import KubixCore

/// The actor is the sole descriptor/decoder owner. Nonblocking syscalls plus bounded sleeps
/// allow full duplex without closing descriptors from cancellation callbacks.
actor UnixPTYBridgeSession: PTYBridgeSession {
    nonisolated let endpoint: ExecBridgeEndpoint
    private let listener: OwnedBridgeListener
    private let clock: any TransportClock
    private let deadline: TimeInterval
    private let released: @Sendable () async -> Void
    private let handshake: BridgeHandshake
    private var connection: (any BridgeConnection)?
    private var decoder = BridgeDecoder()
    private var closed = false
    private var reading = false
    private var writing = false
    private var writeFailed = false
    private var started = false
    private var authenticated = false

    init(
        endpoint: ExecBridgeEndpoint, listener: OwnedBridgeListener, clock: any TransportClock,
        deadline: TimeInterval, released: @escaping @Sendable () async -> Void
    ) {
        self.endpoint = endpoint
        self.listener = listener
        self.clock = clock
        self.deadline = deadline
        self.released = released
        handshake = BridgeHandshake(expectedNonce: endpoint.nonce)
    }

    func initialSize() async throws -> BridgeSize {
        guard !started, !closed else { throw BridgeProtocolError.unexpectedFrame }
        started = true
        do {
            while connection == nil {
                try checkHandshakeDeadline()
                connection = try listener.accept()
                if connection == nil { try await pause() }
            }
            let hello = try await readFrame(handshaking: true)
            try handshake.accept(hello)
            authenticated = true
            let initial = try await readFrame(handshaking: true)
            try handshake.accept(initial)
            guard case .resize(let size) = initial else { throw BridgeProtocolError.unexpectedFrame }
            return size
        } catch {
            await close()
            throw error
        }
    }

    func receive() async throws -> BridgeFrame {
        guard handshake.state == .relaying || handshake.state == .inputClosed else {
            throw BridgeProtocolError.unexpectedFrame
        }
        let frame = try await readFrame(handshaking: false)
        try handshake.accept(frame)
        return frame
    }

    func send(_ frame: BridgeFrame) async throws {
        guard authenticated, !closed, !writing, !writeFailed, let connection else { throw BridgeIOError.unavailable }
        switch frame {
        case .data, .exit, .failure: break
        default: throw BridgeProtocolError.unexpectedFrame
        }
        writing = true
        defer { writing = false }
        do {
            var bytes = try frame.encoded()
            while !bytes.isEmpty {
                try checkOpen()
                let count = try connection.write(bytes)
                if count == 0 { try await pause() } else { bytes.removeFirst(count) }
            }
        } catch {
            // Never append a terminal frame to a partially written, aborted data frame.
            writeFailed = true
            throw error
        }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        connection?.close()
        connection = nil
        listener.close()
        await released()
    }

    private func readFrame(handshaking: Bool) async throws -> BridgeFrame {
        guard !reading else { throw BridgeProtocolError.unexpectedFrame }
        reading = true
        defer { reading = false }
        while true {
            try checkOpen()
            if handshaking { try checkHandshakeDeadline() }
            guard let connection else { throw BridgeIOError.unavailable }
            guard let data = try connection.read(maximumCount: decoder.bytesNeededForFrame) else {
                try await pause()
                continue
            }
            guard !data.isEmpty else {
                try decoder.finish()
                throw ExecFailure.childTerminated
            }
            if let frame = try decoder.append(data).first { return frame }
        }
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw BridgeIOError.unavailable }
    }

    private func checkHandshakeDeadline() throws {
        try checkOpen()
        guard clock.now < deadline else { throw BridgeIOError.unavailable }
    }

    private func pause() async throws {
        // Real scheduling wait, not a liveness clock: injected clocks control the deadline.
        try await Task.sleep(for: .milliseconds(10))
    }
}
