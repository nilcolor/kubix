#if DEBUG
import Darwin
import Foundation
import KubixCore
import Security

/// Opt-in validation of the documented encrypted file backend, never the user's original vault.
public actor IsolatedAWSVaultRunner: ProcessRunning, CustomStringConvertible, CustomReflectable {
    public enum Failure: Error, Equatable, Sendable { case unsafeInvocation, unsafeStorage, randomUnavailable, closed }
    public struct Snapshot: Sendable {
        public let entries: Int
        public let securePermissions: Bool
        public let jweHeadersMatch: Bool
    }
    public nonisolated var description: String { "IsolatedAWSVaultRunner(<redacted>)" }
    public nonisolated var customMirror: Mirror { Mirror(self, children: [:]) }
    public nonisolated let directory: URL
    private let profile: String
    private let process: any ProcessRunning
    private let launches: IsolationLaunches
    private var identity: (dev_t, ino_t)?
    private var passphrase = ""
    private var closed = false
    private var running = 0
    public private(set) var calls = 0
    public var processIDs: [Int32] { launches.values }

    public init(parent: URL, profile: String, process: (any ProcessRunning)? = nil) {
        directory = parent.appendingPathComponent("kubix-vault-" + UUID().uuidString)
        self.profile = profile
        let launches = IsolationLaunches()
        self.launches = launches
        self.process = process ?? ProcessRunner(validationDidLaunch: { launches.append($0) })
    }

    public func prepare() throws -> Snapshot {
        guard !closed else { throw Failure.closed }
        if identity == nil {
            guard directory.isFileURL, !directory.path.utf8.contains(0) else { throw Failure.unsafeStorage }
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.randomUnavailable }
            passphrase = Data(bytes).base64EncodedString()
            guard mkdir(directory.path, 0o700) == 0 else { passphrase = ""; throw Failure.unsafeStorage }
            var info = stat()
            guard lstat(directory.path, &info) == 0 else {
                rmdir(directory.path)
                passphrase = ""
                throw Failure.unsafeStorage
            }
            identity = (info.st_dev, info.st_ino)
        }
        return try snapshot()
    }

    public func run(_ request: ProcessRequest, progress: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        try validate(request)
        let storage = try prepare()
        guard storage.securePermissions, storage.jweHeadersMatch else { throw Failure.unsafeStorage }
        var environment = request.environment
        environment["AWS_VAULT_BACKEND"] = "file"
        environment["AWS_VAULT_FILE_DIR"] = directory.path
        environment["AWS_VAULT_FILE_PASSPHRASE"] = passphrase
        environment["AWS_VAULT_PROFILE_ENV"] = "false"
        environment["AWS_VAULT_STDOUT"] = "true"
        calls += 1
        running += 1
        defer { running -= 1 }
        return try await process.run(ProcessRequest(
            executable: request.executable, arguments: request.arguments, environment: environment,
            timeout: request.timeout, output: request.output
        ), progress: progress)
    }

    public func snapshot() throws -> Snapshot {
        try verifyDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var secure = true
        var encrypted = true
        for file in files {
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else {
                throw Failure.unsafeStorage
            }
            secure = secure && info.st_mode & 0o777 == 0o600
            if encrypted { encrypted = try Self.hasEncryptedHeader(file) }
        }
        return Snapshot(entries: files.count, securePermissions: secure, jweHeadersMatch: encrypted)
    }

    public func cleanup() throws {
        guard running == 0 else { throw Failure.unsafeStorage }
        guard identity != nil else { closed = true; passphrase = ""; return }
        try verifyDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files {
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else {
                throw Failure.unsafeStorage
            }
        }
        for file in files { guard unlink(file.path) == 0 else { throw Failure.unsafeStorage } }
        guard rmdir(directory.path) == 0 else { throw Failure.unsafeStorage }
        identity = nil
        passphrase = ""
        closed = true
    }

    private func verifyDirectory() throws {
        var info = stat()
        guard let identity, lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_dev == identity.0, info.st_ino == identity.1, info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o700 else { throw Failure.unsafeStorage }
    }

    private func validate(_ request: ProcessRequest) throws {
        let arguments = request.arguments
        guard request.executable.lastPathComponent == "aws-vault", request.output == .credential,
              arguments.count > 5, arguments[0] == "exec", arguments[1] == profile,
              let boundary = arguments.firstIndex(of: "--"), boundary >= 2, boundary + 1 < arguments.count,
              arguments[boundary + 1] == "aws",
              arguments.suffix(from: boundary + 2).contains("eks"),
              arguments.suffix(from: boundary + 2).contains("get-token"),
              !arguments.contains("--debug") else { throw Failure.unsafeInvocation }
        let nested = Array(arguments.suffix(from: boundary + 2))
        guard !nested.contains(where: { $0 == "--profile" || $0.hasPrefix("--profile=") }),
              (try? AWSInvocation(configuration: KubeconfigExec(command: "aws", apiVersion: "client.authentication.k8s.io/v1", args: nested))) != nil else {
            throw Failure.unsafeInvocation
        }
        var index = 2
        while index < boundary {
            if arguments[index] == "--duration", index + 1 < boundary, !arguments[index + 1].hasPrefix("-") {
                index += 2
            } else if arguments[index].hasPrefix("--duration=") {
                index += 1
            } else { throw Failure.unsafeInvocation }
        }
    }

    private static func hasEncryptedHeader(_ file: URL) throws -> Bool {
        let bytes = try Data(contentsOf: file)
        guard bytes.count < 1_048_576, let text = String(data: bytes, encoding: .utf8) else { return false }
        let segments = text.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 5 else { return false }
        var header = String(segments[0]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        header += String(repeating: "=", count: (4 - header.count % 4) % 4)
        guard let data = Data(base64Encoded: header),
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return fields["alg"] as? String == "PBES2-HS256+A128KW" && fields["enc"] as? String == "A256GCM"
    }
}

private final class IsolationLaunches: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: [Int32] = []
    var values: [Int32] { lock.withLock { pids } }
    func append(_ pid: Int32) { lock.withLock { pids.append(pid) } }
}
#endif
