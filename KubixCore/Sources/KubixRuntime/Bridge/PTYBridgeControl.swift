import Darwin
import Foundation

/// Callbacks only coalesce notifications; the worker checks at least every 20ms. They never
/// close descriptors or touch IO, so a late signal/cancel cannot race descriptor reuse.
final class PTYBridgeControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var resized = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func resize() { lock.withLock { resized = true } }
    func takeResize() -> Bool {
        lock.withLock {
            defer { resized = false }
            return resized
        }
    }
}

/// Installed only by the executable entry, not by embedded/runtime tests. SIG_IGN is a C
/// disposition, not a Swift POSIX handler; all work runs on a normal Dispatch queue.
final class PTYBridgeSignals {
    private var sources: [any DispatchSourceSignal] = []
    private var previous: [(Int32, sigaction)] = []

    init(control: PTYBridgeControl) throws {
        for number in [SIGWINCH, SIGTERM, SIGHUP, SIGINT, SIGQUIT] {
            var action = sigaction()
            guard sigaction(number, nil, &action) == 0 else { throw BridgeIOError.unavailable }
            previous.append((number, action))
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                if number == SIGWINCH { control.resize() } else { control.cancel() }
            }
            sources.append(source)
            source.resume()
        }
    }

    deinit {
        for source in sources { source.cancel() }
        for (number, var action) in previous { sigaction(number, &action, nil) }
    }
}
