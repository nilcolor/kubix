import Darwin
import Foundation
import KubixCore

/// Nonblocking, worker-confined IO. nil/zero means retry later, empty read means peer EOF.
/// close is idempotent and is called only by the worker, never from cancellation callbacks.
protocol BridgeConnection: AnyObject {
    var descriptor: Int32 { get }
    func read(maximumCount: Int) throws -> Data?
    func write(_ bytes: Data) throws -> Int
    func close()
}

protocol BridgeConnecting: Sendable {
    func connect(
        path: String, control: PTYBridgeControl, clock: any TransportClock
    ) throws -> any BridgeConnection
}

final class UnixBridgeConnection: BridgeConnection {
    private(set) var descriptor: Int32
    typealias Read = (Int32, UnsafeMutableRawPointer, Int) -> Int
    typealias Write = (Int32, UnsafeRawPointer, Int) -> Int
    private let readCall: Read
    private let writeCall: Write

    /// Takes ownership even on setup failure. Syscall injection exercises real partial/EINTR IO.
    init(
        owning descriptor: Int32,
        read: @escaping Read = { Darwin.read($0, $1, $2) },
        write: @escaping Write = { Darwin.write($0, $1, $2) }
    ) throws {
        self.descriptor = descriptor
        readCall = read
        writeCall = write
        do {
            try BridgeIO.nonblocking(descriptor)
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw BridgeIOError.unavailable }
            var enabled: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw BridgeIOError.unavailable
            }
        } catch {
            close()
            throw error
        }
    }

    func read(maximumCount: Int) throws -> Data? {
        try BridgeIO.read(descriptor, maximumCount: maximumCount, call: readCall)
    }

    func write(_ bytes: Data) throws -> Int {
        try BridgeIO.write(descriptor, bytes: bytes, call: writeCall)
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { close() }
}

struct UnixBridgeConnector: BridgeConnecting {
    func connect(
        path: String, control: PTYBridgeControl, clock: any TransportClock
    ) throws -> any BridgeConnection {
        try BridgeSocketPath.validate(path)
        try validateFile(path)
        guard !control.isCancelled else { throw CancellationError() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeIOError.unavailable }
        let connection = try UnixBridgeConnection(owning: fd)
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { target in
                target.copyBytes(from: path.utf8)
            }
            let status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if status != 0 {
                guard errno == EINPROGRESS || errno == EINTR || errno == EAGAIN else { throw BridgeIOError.unavailable }
                try awaitConnection(fd, control: control, clock: clock)
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw BridgeIOError.unavailable }
            guard !control.isCancelled else { throw CancellationError() }
            return connection
        } catch {
            connection.close()
            throw error
        }
    }

    private func validateFile(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw BridgeIOError.unavailable }
        defer { Darwin.close(directory) }
        var parent = stat()
        var socket = stat()
        guard fstat(directory, &parent) == 0, parent.st_uid == geteuid(), parent.st_mode & 0o777 == 0o700,
              fstatat(directory, url.lastPathComponent, &socket, AT_SYMLINK_NOFOLLOW) == 0,
              socket.st_mode & S_IFMT == S_IFSOCK, socket.st_uid == geteuid(), socket.st_mode & 0o777 == 0o600 else {
            throw BridgeIOError.unavailable
        }
    }

    private func awaitConnection(_ fd: Int32, control: PTYBridgeControl, clock: any TransportClock) throws {
        let deadline = clock.now + 5
        while !control.isCancelled && clock.now < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let count = Darwin.poll(&descriptor, 1, 20)
            if count < 0 && errno != EINTR { throw BridgeIOError.unavailable }
            guard count > 0 else { continue }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw BridgeIOError.unavailable
            }
            return
        }
        if control.isCancelled { throw CancellationError() }
        throw BridgeIOError.unavailable
    }
}

enum BridgeIO {
    static func nonblocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw BridgeIOError.unavailable }
    }

    static func read(
        _ fd: Int32, maximumCount: Int, call: UnixBridgeConnection.Read = { Darwin.read($0, $1, $2) }
    ) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: maximumCount)
        let count = call(fd, &bytes, bytes.count)
        if count >= 0 { return Data(bytes.prefix(count)) }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return nil }
        throw BridgeIOError.unavailable
    }

    static func write(
        _ fd: Int32, bytes: Data, call: UnixBridgeConnection.Write = { Darwin.write($0, $1, $2) }
    ) throws -> Int {
        guard !bytes.isEmpty else { return 0 }
        let count = bytes.withUnsafeBytes { call(fd, $0.baseAddress!, $0.count) }
        if count >= 0 { return count }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return 0 }
        throw BridgeIOError.unavailable
    }
}
