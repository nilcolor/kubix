import Foundation

/// Pure addressing only: the runtime must create and own the supplied short, absolute private
/// directory (0700) and session sockets (0600), then clean up only its own resources.
/// No HOME/TMPDIR lookup, filesystem access, normalization, or truncation occurs here.
public struct BridgeSocketPath: Equatable, Sendable {
    public static let darwinPathByteCapacity = 104
    public let value: String

    public init(runtimeDirectory: String, sessionID: UUID) throws {
        try Self.validate(runtimeDirectory)
        let path = runtimeDirectory + "/" + sessionID.uuidString.lowercased() + ".sock"
        try Self.validate(path)
        value = path
    }

    /// Also usable for the child's environment-supplied path before any bind/connect.
    /// Counts UTF-8 bytes *including* the terminating NUL in Darwin sockaddr_un.sun_path.
    public static func validate(_ path: String) throws {
        guard path.hasPrefix("/"), path != "/", !path.utf8.contains(0) else { throw BridgeProtocolError.invalidSocketPath }
        guard path.utf8.count < darwinPathByteCapacity else { throw BridgeProtocolError.socketPathTooLong }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw BridgeProtocolError.invalidSocketPath
        }
    }
}
