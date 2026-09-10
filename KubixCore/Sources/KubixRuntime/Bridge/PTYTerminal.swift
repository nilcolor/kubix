import Darwin
import KubixCore

enum BridgeIOError: Error {
    case unavailable
}

/// The relay's worker alone owns this duplicate and the saved line discipline.
final class PTYTerminal {
    let descriptor: Int32
    private var saved: termios
    private var needsRestore = false

    init(descriptor: Int32) throws {
        let owned = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard owned >= 0 else { throw BridgeIOError.unavailable }
        var attributes = termios()
        guard isatty(owned) == 1, tcgetattr(owned, &attributes) == 0 else {
            Darwin.close(owned)
            throw BridgeIOError.unavailable
        }
        self.descriptor = owned
        saved = attributes
    }

    func makeRaw() throws {
        var raw = saved
        cfmakeraw(&raw)
        needsRestore = true
        try setAttributes(&raw)
    }

    func size() throws -> BridgeSize {
        var size = winsize()
        guard ioctl(descriptor, TIOCGWINSZ, &size) == 0 else { throw BridgeIOError.unavailable }
        return BridgeSize(columns: size.ws_col, rows: size.ws_row)
    }

    func restore() throws {
        guard needsRestore else { return }
        try setAttributes(&saved)
        // Darwin synthesizes the read-only PENDIN bit on the canonical-mode transition.
        // FIONREAD lets the line discipline process it without consuming or flushing bytes.
        if saved.c_lflag & tcflag_t(PENDIN) == 0 {
            var available: Int32 = 0
            // Swift cannot import Darwin's _IOR('f', 127, int) macro.
            let bytesAvailable: UInt = 0x4004667f
            guard ioctl(descriptor, bytesAvailable, &available) == 0 else { throw BridgeIOError.unavailable }
        }
        needsRestore = false
    }

    private func setAttributes(_ attributes: inout termios) throws {
        while tcsetattr(descriptor, TCSANOW, &attributes) != 0 {
            guard errno == EINTR else { throw BridgeIOError.unavailable }
        }
    }

    deinit {
        try? restore()
        Darwin.close(descriptor)
    }
}
