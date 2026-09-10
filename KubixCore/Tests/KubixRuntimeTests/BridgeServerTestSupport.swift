import Darwin
import Foundation
import KubixCore
@testable import KubixRuntime

final class BridgeDirectoryCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var created: [String] { lock.withLock { paths } }

    func create(suffix: String = "b-XXXXXX") throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var template = Array(root.appendingPathComponent(suffix).path.utf8CString)
        guard let made = mkdtemp(&template) else { throw BridgeIOError.unavailable }
        let path = String(cString: made)
        lock.withLock { paths.append(path) }
        return path
    }
}

actor BridgeServerClient {
    private let connection: any BridgeConnection
    private var decoder = BridgeDecoder()

    init(endpoint: ExecBridgeEndpoint) throws {
        connection = try UnixBridgeConnector().connect(
            path: endpoint.socketPath, control: PTYBridgeControl(), clock: ContinuousTransportClock()
        )
    }

    func handshake(_ endpoint: ExecBridgeEndpoint, size: BridgeSize = .init(columns: 90, rows: 30)) async throws {
        try await write(BridgeFrame.hello(endpoint.nonce).encoded() + BridgeFrame.resize(size).encoded())
    }

    func write(_ data: Data) async throws {
        var data = data
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !data.isEmpty {
            guard ContinuousClock.now < deadline else { throw TestFailure.deadline }
            let written = try connection.write(data)
            if written == 0 { try await Task.sleep(for: .milliseconds(1)) } else { data.removeFirst(written) }
        }
    }

    func frame() async throws -> BridgeFrame {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            guard ContinuousClock.now < deadline else { throw TestFailure.deadline }
            if let bytes = try connection.read(maximumCount: decoder.bytesNeededForFrame) {
                guard !bytes.isEmpty else { throw ExecFailure.childTerminated }
                if let frame = try decoder.append(bytes).first { return frame }
            } else { try await Task.sleep(for: .milliseconds(1)) }
        }
    }

    func close() { connection.close() }
    func closeInput() { shutdown(connection.descriptor, SHUT_WR) }
}

func bridgeFileMode(_ path: String) throws -> mode_t {
    var info = stat()
    guard lstat(path, &info) == 0 else { throw BridgeIOError.unavailable }
    return info.st_mode & 0o777
}

func bridgeFileExists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

func withServerSession(
    server: PTYBridgeServer,
    body: (any PTYBridgeSession, BridgeServerClient) async throws -> Void
) async throws {
    let session = try await server.prepare(sessionID: UUID())
    do {
        let client = try BridgeServerClient(endpoint: session.endpoint)
        do { try await body(session, client) } catch {
            await client.close()
            throw error
        }
        await client.close()
        await session.close()
    } catch {
        await session.close()
        throw error
    }
}
