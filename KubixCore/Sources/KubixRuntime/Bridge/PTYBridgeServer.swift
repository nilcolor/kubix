import Darwin
import Foundation
import KubixCore
import Security

/// Pull-based duplex IO: one reader and one writer, no unbounded producer queues.
/// Each operation must cooperate with task cancellation; close unblocks all pending operations.
protocol PTYBridgeSession: Sendable {
    var endpoint: ExecBridgeEndpoint { get }
    func initialSize() async throws -> BridgeSize
    func receive() async throws -> BridgeFrame
    func send(_ frame: BridgeFrame) async throws
    func close() async
}

protocol PTYBridgeServing: Sendable {
    func prepare(sessionID: UUID) async throws -> any PTYBridgeSession
}

public actor PTYBridgeServer: PTYBridgeServing {
    private let makeDirectory: @Sendable () throws -> String
    private let clock: any TransportClock
    private let handshakeTimeout: TimeInterval
    private var directory: OwnedBridgeDirectory?
    private var sessions: Set<UUID> = []

    public init() {
        makeDirectory = { try OwnedBridgeDirectory.create() }
        clock = ContinuousTransportClock()
        handshakeTimeout = 5
    }

    #if DEBUG
    init(validationRoot: URL) {
        makeDirectory = {
            let path = validationRoot.appendingPathComponent("v-" + UUID().uuidString.prefix(6)).path
            guard validationRoot.isFileURL, mkdir(path, 0o700) == 0 else { throw BridgeIOError.unavailable }
            return path
        }
        clock = ContinuousTransportClock()
        handshakeTimeout = 5
    }
    #endif

    /// Controlled local tests inject creation without consulting HOME or TMPDIR.
    init(
        makeDirectory: @escaping @Sendable () throws -> String,
        clock: any TransportClock = ContinuousTransportClock(), handshakeTimeout: TimeInterval = 5
    ) {
        self.makeDirectory = makeDirectory
        self.clock = clock
        self.handshakeTimeout = handshakeTimeout
    }

    func prepare(sessionID: UUID) throws -> any PTYBridgeSession {
        try Task.checkCancellation()
        guard !sessions.contains(sessionID) else { throw BridgeIOError.unavailable }
        if directory == nil { directory = try OwnedBridgeDirectory(path: makeDirectory()) }
        guard let directory else { throw BridgeIOError.unavailable }
        do {
            let path = try BridgeSocketPath(runtimeDirectory: directory.path, sessionID: sessionID).value
            let listener = try OwnedBridgeListener(path: path)
            var bytes = [UInt8](repeating: 0, count: BridgeNonce.byteCount)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw BridgeIOError.unavailable
            }
            let endpoint = try ExecBridgeEndpoint(socketPath: path, nonce: BridgeNonce(bytes: Data(bytes)))
            sessions.insert(sessionID)
            return UnixPTYBridgeSession(
                endpoint: endpoint, listener: listener, clock: clock,
                deadline: clock.now + handshakeTimeout,
                released: { await self.release(sessionID) }
            )
        } catch {
            if sessions.isEmpty { self.directory = nil }
            throw error
        }
    }

    private func release(_ sessionID: UUID) {
        sessions.remove(sessionID)
        // A later prepare creates a fresh directory, never a path we already removed.
        if sessions.isEmpty { directory = nil }
    }
}

/// Only exact inodes created by this owner are ever unlinked; no directory scans or recursive removal.
final class OwnedBridgeDirectory {
    let path: String
    private let identity: BridgeFileIdentity

    static func create() throws -> String {
        var template = Array("/tmp/kubix-XXXXXX".utf8CString)
        guard let path = mkdtemp(&template) else { throw BridgeIOError.unavailable }
        return String(cString: path)
    }

    init(path: String) throws {
        self.path = path
        identity = try BridgeFileIdentity(path: path, kind: S_IFDIR, permissions: 0o700)
    }

    deinit {
        if identity.matches(path) { rmdir(path) }
    }
}

struct BridgeFileIdentity {
    let device: dev_t
    let inode: ino_t

    init(path: String, kind: mode_t, permissions: mode_t) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == kind, info.st_uid == geteuid(),
              info.st_mode & 0o777 == permissions else { throw BridgeIOError.unavailable }
        device = info.st_dev
        inode = info.st_ino
    }

    func matches(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_dev == device && info.st_ino == inode
    }
}

final class OwnedBridgeListener {
    private(set) var descriptor: Int32 = -1
    private let path: String
    private var identity: BridgeFileIdentity?

    init(path: String) throws {
        try BridgeSocketPath.validate(path)
        self.path = path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeIOError.unavailable }
        descriptor = fd
        do {
            try BridgeIO.nonblocking(fd)
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw BridgeIOError.unavailable }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
            let status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard status == 0 else { throw BridgeIOError.unavailable }
            // Capture identity before chmod so even a later setup failure removes our socket.
            var info = stat()
            guard lstat(path, &info) == 0 else { throw BridgeIOError.unavailable }
            identity = try BridgeFileIdentity(path: path, kind: S_IFSOCK, permissions: info.st_mode & 0o777)
            guard chmod(path, 0o600) == 0, listen(fd, 1) == 0 else { throw BridgeIOError.unavailable }
        } catch {
            close()
            throw error
        }
    }

    func accept() throws -> (any BridgeConnection)? {
        guard descriptor >= 0 else { throw BridgeIOError.unavailable }
        let fd = Darwin.accept(descriptor, nil, nil)
        if fd < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return nil }
            throw BridgeIOError.unavailable
        }
        let connection = try UnixBridgeConnection(owning: fd)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
            connection.close()
            throw BridgeIOError.unavailable
        }
        // One attempt only, including a bad nonce or a silent peer. No second child can attach.
        stopAccepting()
        return connection
    }

    func stopAccepting() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        // Removing only our socket name also prevents connects through an inherited listener alias.
        if let identity, identity.matches(path) { unlink(path) }
        identity = nil
    }

    func close() { stopAccepting() }

    deinit { close() }
}
