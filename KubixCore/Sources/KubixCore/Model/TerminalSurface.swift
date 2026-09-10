/// App-owned terminal adapters must make teardown idempotent and must never recreate a closed surface.
@MainActor
public protocol TerminalSurface: AnyObject {
    func teardown()
}

/// The session owns this lifetime, not the UI representable. Close before releasing the session.
@MainActor
public final class TerminalSurfaceLifetime {
    public private(set) var surface: (any TerminalSurface)?

    public init(surface: any TerminalSurface) {
        self.surface = surface
    }

    public func close() {
        let closing = surface
        surface = nil
        closing?.teardown()
    }
}
