import Darwin
import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

struct PTYSnapshot: Equatable, Sendable {
    let flags: [tcflag_t]
    let controls: Data
    let speeds: [speed_t]

    init(_ fd: Int32) throws {
        var attributes = termios()
        guard tcgetattr(fd, &attributes) == 0 else { throw BridgeIOError.unavailable }
        flags = [attributes.c_iflag, attributes.c_oflag, attributes.c_cflag, attributes.c_lflag]
        controls = withUnsafeBytes(of: attributes.c_cc) { Data($0) }
        speeds = [cfgetispeed(&attributes), cfgetospeed(&attributes)]
    }
}

final class TestPTY: Sendable {
    private static let allocationLock = NSLock()
    let controller: Int32
    let terminal: Int32
    let original: PTYSnapshot

    init() throws {
        // Darwin's openpty path discovery uses libc state; only allocation is serialized.
        Self.allocationLock.lock()
        defer { Self.allocationLock.unlock() }
        var controller: Int32 = -1
        var terminal: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&controller, &terminal, nil, nil, &size) == 0 else { throw BridgeIOError.unavailable }
        self.controller = controller
        self.terminal = terminal
        var attributes = termios()
        guard tcgetattr(terminal, &attributes) == 0 else { throw BridgeIOError.unavailable }
        attributes.c_lflag |= tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        attributes.c_iflag |= tcflag_t(ICRNL | IXON)
        attributes.c_oflag |= tcflag_t(OPOST | ONLCR)
        guard tcsetattr(terminal, TCSANOW, &attributes) == 0 else { throw BridgeIOError.unavailable }
        original = try PTYSnapshot(terminal)
        try BridgeIO.nonblocking(controller)
    }

    func resize(columns: UInt16, rows: UInt16) throws {
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(terminal, TIOCSWINSZ, &size) == 0 else { throw BridgeIOError.unavailable }
    }

    deinit { Darwin.close(controller); Darwin.close(terminal) }
}

final class TestBridgePipe {
    let reader: Int32
    private(set) var writer: Int32
    init() throws {
        var pair: [Int32] = [-1, -1]
        guard pipe(&pair) == 0 else { throw BridgeIOError.unavailable }
        reader = pair[0]
        writer = pair[1]
        try BridgeIO.nonblocking(reader)
        try BridgeIO.nonblocking(writer)
        _ = fcntl(writer, F_SETNOSIGPIPE, 1)
    }
    func closeWriter() {
        if writer >= 0 { Darwin.close(writer); writer = -1 }
    }
    deinit { Darwin.close(reader); closeWriter() }
}

final class TestBridgeConnector: BridgeConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var owned: Int32
    private(set) var peer: Int32
    let chunk: Int
    let interrupt: Bool
    let stallAfterHandshake: Bool
    private var calls = 0
    private var readCount = 0
    private var blockedWrites = 0

    init(chunk: Int = 65_536, interrupt: Bool = false, stallAfterHandshake: Bool = false) throws {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw BridgeIOError.unavailable }
        owned = pair[0]
        peer = pair[1]
        self.chunk = chunk
        self.interrupt = interrupt
        self.stallAfterHandshake = stallAfterHandshake
        try BridgeIO.nonblocking(peer)
        var size: Int32 = 4_096
        setsockopt(owned, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(peer, F_SETNOSIGPIPE, 1)
    }

    var connectionCount: Int { lock.withLock { calls } }
    var bytesRead: Int { lock.withLock { readCount } }
    var encounteredBackpressure: Bool { lock.withLock { blockedWrites > 0 } }

    func closePeer() {
        if peer >= 0 { Darwin.close(peer); peer = -1 }
    }

    func connect(path: String, control: PTYBridgeControl, clock: any TransportClock) throws -> any BridgeConnection {
        let fd = lock.withLock {
            defer { owned = -1; calls += 1 }
            return owned
        }
        var firstRead = interrupt
        var firstWrite = interrupt
        var written = 0
        return try UnixBridgeConnection(
            owning: fd,
            read: { fd, bytes, count in
                if firstRead { firstRead = false; errno = EINTR; return -1 }
                let count = Darwin.read(fd, bytes, min(count, self.chunk))
                if count > 0 { self.lock.withLock { self.readCount += count } }
                return count
            },
            write: { fd, bytes, count in
                if firstWrite { firstWrite = false; errno = EINTR; return -1 }
                if self.stallAfterHandshake && written >= 46 { errno = EAGAIN; return -1 }
                let count = Darwin.write(fd, bytes, min(count, self.chunk))
                if count > 0 { written += count }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    self.lock.withLock { self.blockedWrites += 1 }
                }
                return count
            }
        )
    }

    deinit {
        if owned >= 0 { Darwin.close(owned) }
        closePeer()
    }
}

final class BridgeTestRun: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    let control = PTYBridgeControl()
    private var storedResult: PTYBridgeResult?
    private var storedDiagnostic = ""
    private var restoredAtDiagnostic = false

    init(
        child: PTYBridgeChild, environment: [String: String], input: Int32, output: Int32, tty: TestPTY
    ) {
        let beforeInput = bridgeStatusFlags(input)
        let beforeOutput = bridgeStatusFlags(output)
        group.enter()
        DispatchQueue(label: "kubix.test.bridge.\(UUID())").async { [self] in
            let result = child.run(
                environment: environment, input: input, output: output, terminal: tty.terminal, control: control
            ) { message in
                let restored = (try? PTYSnapshot(tty.terminal)) == tty.original
                    && bridgeStatusFlags(input) == beforeInput && bridgeStatusFlags(output) == beforeOutput
                lock.withLock {
                    storedDiagnostic = message
                    restoredAtDiagnostic = restored
                }
            }
            lock.withLock { storedResult = result }
            group.leave()
        }
    }

    var diagnostic: String { lock.withLock { storedDiagnostic } }
    var diagnosticAfterRestoration: Bool { lock.withLock { restoredAtDiagnostic } }
    var finished: Bool { lock.withLock { storedResult != nil } }

    func wait(seconds: Double = 5) throws -> PTYBridgeResult {
        guard group.wait(timeout: .now() + seconds) == .success,
              let result = lock.withLock({ storedResult }) else { throw TestFailure.deadline }
        return result
    }

    func stop() {
        control.cancel()
        #expect(group.wait(timeout: .now() + 4) == .success)
    }
}

final class BridgeTestSession {
    let tty: TestPTY
    let connector: TestBridgeConnector
    let inputPipe: TestBridgePipe?
    let outputPipe: TestBridgePipe?
    let nonce = try! BridgeNonce(bytes: Data(0..<32))
    var run: BridgeTestRun?
    var input: Int32 { inputPipe?.reader ?? tty.terminal }
    var inputWriter: Int32 { inputPipe?.writer ?? tty.controller }
    var output: Int32 { outputPipe?.writer ?? tty.terminal }
    var outputReader: Int32 { outputPipe?.reader ?? tty.controller }
    var environment: [String: String] {
        ["KUBIX_BRIDGE_SOCK": "/synthetic/bridge.sock", "KUBIX_BRIDGE_NONCE": nonce.environmentValue]
    }
    private var decoder = BridgeDecoder()
    private var frames: [BridgeFrame] = []

    init(
        inputPipe: Bool = false, outputPipe: Bool = false, chunk: Int = 65_536,
        interrupt: Bool = false, stallAfterHandshake: Bool = false
    ) throws {
        tty = try TestPTY()
        connector = try TestBridgeConnector(chunk: chunk, interrupt: interrupt, stallAfterHandshake: stallAfterHandshake)
        self.inputPipe = inputPipe ? try TestBridgePipe() : nil
        self.outputPipe = outputPipe ? try TestBridgePipe() : nil
    }

    @discardableResult func start() -> BridgeTestRun {
        let run = BridgeTestRun(
            child: PTYBridgeChild(connector: connector), environment: environment, input: input, output: output, tty: tty
        )
        self.run = run
        return run
    }

    func handshake() throws {
        #expect(try nextFrame() == .hello(nonce))
        #expect(try nextFrame() == .resize(BridgeSize(columns: 80, rows: 24)))
    }

    func nextFrame() throws -> BridgeFrame {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while frames.isEmpty {
            guard ContinuousClock.now < deadline else { throw TestFailure.deadline }
            if let bytes = try BridgeIO.read(connector.peer, maximumCount: 4_096) {
                guard !bytes.isEmpty else { throw BridgeIOError.unavailable }
                frames += try decoder.append(bytes)
            } else { try bridgeWait(connector.peer, events: Int16(POLLIN), milliseconds: 20) }
        }
        return frames.removeFirst()
    }

    func send(_ frame: BridgeFrame) throws { try bridgeWrite(connector.peer, bytes: frame.encoded()) }

    func stop() { run?.stop() }
}

func bridgeWait(_ fd: Int32, events: Int16, milliseconds: Int32 = 20) throws {
    var descriptor = pollfd(fd: fd, events: events, revents: 0)
    if Darwin.poll(&descriptor, 1, milliseconds) < 0 && errno != EINTR { throw BridgeIOError.unavailable }
}

func bridgeWrite(_ fd: Int32, bytes: Data) throws {
    var pending = bytes
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !pending.isEmpty {
        guard ContinuousClock.now < deadline else { throw TestFailure.deadline }
        let count = try BridgeIO.write(fd, bytes: pending)
        pending.removeFirst(count)
        if count == 0 { try bridgeWait(fd, events: Int16(POLLOUT)) }
    }
}

func bridgeRead(_ fd: Int32, count: Int) throws -> Data {
    var result = Data()
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while result.count < count {
        guard ContinuousClock.now < deadline else { throw TestFailure.deadline }
        if let bytes = try BridgeIO.read(fd, maximumCount: count - result.count) {
            guard !bytes.isEmpty else { throw BridgeIOError.unavailable }
            result.append(bytes)
        } else { try bridgeWait(fd, events: Int16(POLLIN)) }
    }

    return result
}

func bridgeStatusFlags(_ fd: Int32) -> Int32 {
    // Darwin adds an immutable kernel "has been written" bit after a write. Compare public
    // access/status flags, not that kernel-only bit; the relay restores every flag it changes.
    fcntl(fd, F_GETFL) & (O_ACCMODE | O_NONBLOCK | O_APPEND | O_ASYNC | O_SYNC | O_DSYNC)
}

func bridgeEventually(_ condition: () -> Bool) throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TestFailure.deadline }
        Thread.sleep(forTimeInterval: 0.001)
    }
}
