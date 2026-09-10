import Darwin
import Foundation

public enum ProcessFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidRequest, launchFailed, timedOut, outputLimit, exited(Int32), pipeFailed

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The authentication process requires an absolute executable and a positive deadline."
        case .launchFailed: "The authentication executable could not be launched. Configure Plugin Path."
        case .timedOut: "Authentication timed out. Retry or increase the authentication deadline."
        case .outputLimit: "The authentication process exceeded the credential output limit."
        case .exited(let code): "Authentication exited with status \(code). Check the configured plugin/profile or explicitly Sign in."
        case .pipeFailed: "Authentication process output could not be read."
        }
    }
}

public struct ProcessRequest: Sendable, CustomStringConvertible, CustomReflectable {
    public enum Output: Sendable { case credential, instructions }
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let timeout: TimeInterval
    public let output: Output
    public var description: String { "ProcessRequest (redacted)" }
    public var customMirror: Mirror { Mirror(self, children: ["contents": "redacted"]) }

    public init(
        executable: URL, arguments: [String], environment: [String: String],
        timeout: TimeInterval, output: Output = .credential
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.output = output
    }
}

public struct ProcessResult: Sendable, CustomStringConvertible, CustomReflectable {
    public let stdout: Data
    public let exitCode: Int32
    public var description: String { "ProcessResult (redacted)" }
    public var customMirror: Mirror { Mirror(self, children: ["contents": "redacted"]) }

    public init(stdout: Data, exitCode: Int32) {
        self.stdout = stdout
        self.exitCode = exitCode
    }
}

public protocol ProcessRunning: Sendable {
    /// stdout is delivered to progress ONLY in instructions mode. stderr is always transient.
    func run(_ request: ProcessRequest, progress: @escaping @Sendable (String) -> Void) async throws -> ProcessResult
}

/// A detached worker polls both nonblocking pipes. No blocking read/waitUntilExit is used: even an
/// inherited pipe held by a descendant cannot prevent deadline/cancellation or completion.
public struct ProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        _ request: ProcessRequest, progress: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        let cancellation = ProcessCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached {
                try Self.execute(request, cancellation: cancellation, progress: progress)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func execute(
        _ request: ProcessRequest, cancellation: ProcessCancellation,
        progress: @escaping @Sendable (String) -> Void
    ) throws -> ProcessResult {
        guard request.executable.isFileURL, request.executable.path.hasPrefix("/"),
              request.timeout.isFinite, request.timeout > 0 else { throw ProcessFailure.invalidRequest }
        try validateStrings(request)
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        defer {
            try? stdout.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForReading.close()
            try? stderr.fileHandleForWriting.close()
        }
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        guard !cancellation.isCancelled else { throw CancellationError() }
        do { try process.run() } catch { throw ProcessFailure.launchFailed }
        // Foundation's macOS Process creates a process group. Signal it only after verifying ownership;
        // never signal the caller's group if a different Foundation implementation is injected.
        let pid = process.processIdentifier
        let ownsGroup = getpgid(pid) == pid
        defer {
            if ownsGroup { _ = Darwin.kill(-pid, SIGKILL) }
            if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
        }
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()
        let outFD = stdout.fileHandleForReading.fileDescriptor
        let errFD = stderr.fileHandleForReading.fileDescriptor
        guard fcntl(outFD, F_SETFL, O_NONBLOCK) != -1, fcntl(errFD, F_SETFL, O_NONBLOCK) != -1 else {
            throw ProcessFailure.pipeFailed
        }
        return try drain(process, fds: [outFD, errFD], request: request, cancellation: cancellation, progress: progress)
    }

    private static func validateStrings(_ request: ProcessRequest) throws {
        guard !request.executable.path.contains("\0"),
              request.arguments.allSatisfy({ !$0.contains("\0") }),
              request.environment.allSatisfy({
                  !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0")
              }) else { throw ProcessFailure.invalidRequest }
    }

    private static func drain(
        _ process: Process, fds: [Int32], request: ProcessRequest,
        cancellation: ProcessCancellation, progress: @escaping @Sendable (String) -> Void
    ) throws -> ProcessResult {
        let deadline = ContinuousClock.now.advanced(by: .seconds(request.timeout))
        var pipes = ProcessOutputPipes(fds: fds, mode: request.output, progress: progress)
        while true {
            guard !cancellation.isCancelled else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw ProcessFailure.timedOut }
            let running = process.isRunning
            let received = try pipes.readAvailable()
            if !running && (!received || pipes.allClosed) {
                pipes.finish()
                return ProcessResult(stdout: pipes.output, exitCode: process.terminationStatus)
            }
            if !received { pipes.poll() }
        }
    }
}

private struct ProcessOutputPipes {
    private let fds: [Int32]
    private let mode: ProcessRequest.Output
    private let progress: @Sendable (String) -> Void
    private var decoders = [IncrementalUTF8(), IncrementalUTF8()]
    private var closed = [false, false]
    private var descriptors: [pollfd]
    private(set) var output = Data()
    var allClosed: Bool { closed.allSatisfy { $0 } }

    init(fds: [Int32], mode: ProcessRequest.Output, progress: @escaping @Sendable (String) -> Void) {
        self.fds = fds
        self.mode = mode
        self.progress = progress
        descriptors = fds.map { pollfd(fd: $0, events: Int16(POLLIN | POLLHUP), revents: 0) }
    }

    mutating func readAvailable() throws -> Bool {
        var received = false
        for index in fds.indices where !closed[index] {
            let read = try readAvailable(index)
            received = received || read
        }
        return received
    }

    mutating func poll() { _ = Darwin.poll(&descriptors, nfds_t(descriptors.count), 20) }

    mutating func finish() {
        for index in fds.indices where !closed[index] { finish(index) }
    }

    private mutating func readAvailable(_ index: Int) throws -> Bool {
        var received = false
        // Fairness bounds keep stdout pressure from starving stderr or deadline checks.
        for _ in 0..<16 {
            guard let chunk = try readChunk(fds[index]) else { break }
            if chunk.isEmpty { finish(index); break }
            received = true
            try capture(chunk, index: index)
        }
        return received
    }

    private mutating func capture(_ chunk: Data, index: Int) throws {
        if index == 0 {
            output.append(chunk)
            if mode == .credential {
                guard output.count <= 1_048_576 else { throw ProcessFailure.outputLimit }
            } else if output.count > 8_192 {
                output = output.suffix(8_192)
            }
        }
        if index == 1 || mode == .instructions {
            let text = decoders[index].append(chunk)
            if !text.isEmpty { progress(text) }
        }
    }

    private mutating func finish(_ index: Int) {
        closed[index] = true
        descriptors[index].fd = -1
        if index == 1 || mode == .instructions {
            let tail = decoders[index].finish()
            if !tail.isEmpty { progress(tail) }
        }
    }

    private func readChunk(_ fd: Int32) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count >= 0 { return Data(bytes.prefix(count)) }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return nil }
        throw ProcessFailure.pipeFailed
    }
}

private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Retain only a trailing incomplete scalar, not a whole line; prompts need no newline to appear.
struct IncrementalUTF8 {
    private var pending = [UInt8]()

    mutating func append(_ data: Data) -> String {
        pending.append(contentsOf: data)
        var end = pending.count
        if let lead = pending.lastIndex(where: { $0 & 0xC0 != 0x80 }) {
            let byte = pending[lead]
            let width = byte & 0xF8 == 0xF0 ? 4 : byte & 0xF0 == 0xE0 ? 3 : byte & 0xE0 == 0xC0 ? 2 : 1
            if pending.count - lead < width { end = lead }
        }
        let text = String(decoding: pending.prefix(end), as: UTF8.self)
        pending.removeFirst(end)
        return text
    }

    mutating func finish() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}
