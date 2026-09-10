import Foundation

public struct ExecBridgeEndpoint: Sendable, CustomStringConvertible, CustomReflectable {
    public let socketPath: String
    public let nonce: BridgeNonce

    public init(socketPath: String, nonce: BridgeNonce) throws {
        try BridgeSocketPath.validate(socketPath)
        self.socketPath = socketPath
        self.nonce = nonce
    }

    public var environment: [String: String] {
        ["KUBIX_BRIDGE_SOCK": socketPath, "KUBIX_BRIDGE_NONCE": nonce.environmentValue]
    }

    public var description: String { "ExecBridgeEndpoint(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// run owns all IO until it returns; task cancellation must unblock and join every operation.
/// ready is called only after authentication and listener creation, before the child handshake.
/// finished updates are authoritative and precede local terminal teardown callbacks.
public protocol ExecSessionControlling: Sendable {
    func run(
        sessionID: UUID, target: ExecTarget,
        ready: @escaping @MainActor @Sendable (ExecBridgeEndpoint) throws -> Void,
        update: @escaping @MainActor @Sendable (ExecSession.State) -> Void
    ) async -> ExecSessionResult
    func childTerminated(sessionID: UUID) async
}
