import Darwin
import Foundation

/// Capture both original flags before changing either: stdin/stdout may share an open-file
/// description. Duplicates belong to the worker; caller-owned descriptors are never closed.
final class PTYBridgeDescriptors {
    let input: Int32
    let output: Int32
    private let inputFlags: Int32
    private let outputFlags: Int32
    private let outputNoSignal: Int32

    init(input: Int32, output: Int32) throws {
        inputFlags = fcntl(input, F_GETFL)
        outputFlags = fcntl(output, F_GETFL)
        outputNoSignal = fcntl(output, F_GETNOSIGPIPE)
        self.input = fcntl(input, F_DUPFD_CLOEXEC, 0)
        self.output = fcntl(output, F_DUPFD_CLOEXEC, 0)
        guard self.input >= 0, self.output >= 0, inputFlags >= 0, outputFlags >= 0, outputNoSignal >= 0 else {
            throw BridgeIOError.unavailable
        }
    }

    func prepare() throws {
        try BridgeIO.nonblocking(input)
        try BridgeIO.nonblocking(output)
        guard fcntl(output, F_SETNOSIGPIPE, 1) == 0 else { throw BridgeIOError.unavailable }
    }

    deinit {
        if input >= 0 {
            if inputFlags >= 0 { _ = fcntl(input, F_SETFL, inputFlags) }
            Darwin.close(input)
        }
        if output >= 0 {
            if outputFlags >= 0 { _ = fcntl(output, F_SETFL, outputFlags) }
            if outputNoSignal >= 0 { _ = fcntl(output, F_SETNOSIGPIPE, outputNoSignal) }
            Darwin.close(output)
        }
    }
}

enum PTYBridgeDiagnostic {
    /// Fixed literals only, after restoration. Broken/blocked stderr must not trap the child.
    static func write(_ message: String, descriptor: Int32 = STDERR_FILENO) {
        guard let owned = try? PTYBridgeDescriptors(input: descriptor, output: descriptor) else { return }
        guard (try? owned.prepare()) != nil else { return }
        var pending = Data(message.utf8)
        let deadline = DispatchTime.now().uptimeNanoseconds + 200_000_000
        while !pending.isEmpty && DispatchTime.now().uptimeNanoseconds < deadline {
            guard let count = try? BridgeIO.write(owned.output, bytes: pending) else { return }
            pending.removeFirst(count)
            if count == 0 {
                var fd = pollfd(fd: owned.output, events: Int16(POLLOUT), revents: 0)
                _ = Darwin.poll(&fd, 1, 20)
            }
        }
    }
}
