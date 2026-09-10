import Foundation

/// App-owned terminal adapters must make teardown idempotent and must never recreate a closed surface.
@MainActor
public protocol TerminalSurface: AnyObject {
    func teardown()
}

/// App composition supplies the executable command and actual Ghostty adapter, not core/runtime.
@MainActor
public protocol TerminalSurfaceCreating {
    func makeSurface(
        sessionID: UUID, target: ExecTarget, endpoint: ExecBridgeEndpoint,
        onChildExit: @escaping @MainActor @Sendable () -> Void
    ) throws -> any TerminalSurface
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
