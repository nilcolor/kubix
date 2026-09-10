import Darwin
import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Suite struct BridgeConnectionTests {
    @Test func closeEndsPeerEvenWhenAnotherDescriptorRetainsTheSocket() throws {
        let connector = try TestBridgeConnector()
        let connection = try connector.connect(path: "/unused", control: PTYBridgeControl(), clock: ContinuousTransportClock())
        let retained = dup(connection.descriptor)
        #expect(retained >= 0)
        defer { Darwin.close(retained) }
        connection.close()
        #expect(connection.descriptor == -1)
        let remaining = try BridgeIO.read(connector.peer, maximumCount: 1)
        #expect(remaining == Data())
        #expect(fcntl(retained, F_GETFD) >= 0)
        connection.close()
    }

    @Test func realNamedSocketValidatesPeerAndCarriesTheActualChildLoop() throws {
        let listener = try TestBridgeListener()
        let tty = try TestPTY()
        let nonce = try BridgeNonce(bytes: Data(repeating: 0x42, count: 32))
        let run = BridgeTestRun(
            child: PTYBridgeChild(),
            environment: ["KUBIX_BRIDGE_SOCK": listener.path, "KUBIX_BRIDGE_NONCE": nonce.environmentValue],
            input: tty.terminal, output: tty.terminal, tty: tty
        )
        defer { run.stop() }
        let peer = try listener.accept()
        defer { Darwin.close(peer) }
        #expect(try readBridgeFrame(peer) == .hello(nonce))
        #expect(try readBridgeFrame(peer) == .resize(BridgeSize(columns: 80, rows: 24)))
        try bridgeWrite(tty.controller, bytes: Data([3]))
        #expect(try readBridgeFrame(peer) == .data(Data([3])))
        try bridgeWrite(peer, bytes: BridgeFrame.data(Data([0, 10, 0xff])).encoded() + BridgeFrame.exit(code: 0).encoded())
        #expect(try bridgeRead(tty.controller, count: 3) == Data([0, 10, 0xff]))
        #expect(try run.wait() == .remoteExit(0))
        #expect(try PTYSnapshot(tty.terminal) == tty.original)
    }

    @Test(arguments: [0o755, 0o770, 0o777])
    func insecureDirectoryIsRejectedBeforeConnection(mode: Int) throws {
        let listener = try TestBridgeListener()
        #expect(chmod(listener.directory.path, mode_t(mode)) == 0)
        #expect(throws: BridgeIOError.self) {
            try UnixBridgeConnector().connect(path: listener.path, control: PTYBridgeControl(), clock: ContinuousTransportClock())
        }
    }

    @Test(arguments: [0o644, 0o660, 0o666])
    func insecureSocketIsRejectedBeforeConnection(mode: Int) throws {
        let listener = try TestBridgeListener()
        #expect(chmod(listener.path, mode_t(mode)) == 0)
        #expect(throws: BridgeIOError.self) {
            try UnixBridgeConnector().connect(path: listener.path, control: PTYBridgeControl(), clock: ContinuousTransportClock())
        }
    }

    @Test func socketAndDirectorySymlinksAreRejected() throws {
        let listener = try TestBridgeListener()
        let link = listener.directory.appendingPathComponent("link").path
        #expect(symlink(listener.path, link) == 0)
        #expect(throws: BridgeIOError.self) {
            try UnixBridgeConnector().connect(path: link, control: PTYBridgeControl(), clock: ContinuousTransportClock())
        }
        let parentLink = listener.directory.appendingPathComponent("dirlink").path
        #expect(symlink(listener.directory.path, parentLink) == 0)
        #expect(throws: BridgeIOError.self) {
            try UnixBridgeConnector().connect(path: parentLink + "/session.sock", control: PTYBridgeControl(), clock: ContinuousTransportClock())
        }
    }

    @Test func regularFileAndAbsentSocketAreRejectedWithoutExposingPaths() throws {
        let listener = try TestBridgeListener()
        let file = listener.directory.appendingPathComponent("file").path
        let descriptor = open(file, O_CREAT | O_WRONLY | O_EXCL, 0o600)
        #expect(descriptor >= 0)
        Darwin.close(descriptor)
        for path in [file, listener.directory.appendingPathComponent("missing").path] {
            #expect(throws: BridgeIOError.self) {
                try UnixBridgeConnector().connect(path: path, control: PTYBridgeControl(), clock: ContinuousTransportClock())
            }
        }
    }

    @Test func brokenSocketWriteSurvivesSIGPIPEAndCloseIsIdempotent() throws {
        let connector = try TestBridgeConnector()
        let connection = try connector.connect(path: "/unused", control: PTYBridgeControl(), clock: ContinuousTransportClock())
        #expect(fcntl(connection.descriptor, F_GETFD) & FD_CLOEXEC != 0)
        connector.closePeer()
        #expect(throws: BridgeIOError.self) { try connection.write(Data([42])) }
        connection.close()
        let probe = try TestBridgePipe()
        connection.close()
        try bridgeWrite(probe.writer, bytes: Data([1]))
        #expect(try bridgeRead(probe.reader, count: 1) == Data([1]))
        #expect(connection.descriptor == -1)
    }

    @Test func connectionFailureRestoresOriginalDescriptorFlagsAndTTYBeforeDiagnostic() throws {
        let listener = try TestBridgeListener()
        #expect(chmod(listener.path, 0o666) == 0)
        let tty = try TestPTY()
        let nonce = try BridgeNonce(bytes: Data(repeating: 1, count: 32))
        let run = BridgeTestRun(
            child: PTYBridgeChild(),
            environment: ["KUBIX_BRIDGE_SOCK": listener.path, "KUBIX_BRIDGE_NONCE": nonce.environmentValue],
            input: tty.terminal, output: tty.terminal, tty: tty
        )
        defer { run.stop() }
        #expect(try run.wait() == .localFailure(.connection))
        #expect(run.diagnosticAfterRestoration)
        #expect(run.diagnostic == "kubix: The terminal connection failed.\n")
    }
}

/// Test-only listener; this is deliberately not the future parent/session server.
private final class TestBridgeListener {
    let directory: URL
    let path: String
    private let descriptor: Int32

    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = package.deletingLastPathComponent().appendingPathComponent(".build/b-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("session.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        do {
            try BridgeSocketPath.validate(path)
            guard fd >= 0 else { throw BridgeIOError.unavailable }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
            let status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard status == 0, chmod(path, 0o600) == 0, listen(fd, 1) == 0 else { throw BridgeIOError.unavailable }
            try BridgeIO.nonblocking(fd)
        } catch {
            if fd >= 0 { Darwin.close(fd) }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.directory = directory
        self.path = path
        descriptor = fd
    }

    func accept() throws -> Int32 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let peer = Darwin.accept(descriptor, nil, nil)
            if peer >= 0 {
                try BridgeIO.nonblocking(peer)
                _ = fcntl(peer, F_SETNOSIGPIPE, 1)
                return peer
            }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { throw BridgeIOError.unavailable }
            try bridgeWait(descriptor, events: Int16(POLLIN))
        }
        throw TestFailure.deadline
    }

    deinit {
        Darwin.close(descriptor)
        try? FileManager.default.removeItem(at: directory)
    }
}

private func readBridgeFrame(_ fd: Int32) throws -> BridgeFrame {
    var decoder = BridgeDecoder()
    while true {
        let bytes = try bridgeRead(fd, count: decoder.bytesNeededForFrame)
        if let frame = try decoder.append(bytes).first { return frame }
    }
}
