import Foundation

/// Transient UI instructions only. Implementations must never pass credential stdout to this sink.
public typealias AuthProgress = @Sendable (String) -> Void

public struct AcquiredCredential: Sendable, CustomStringConvertible, CustomReflectable {
    public let identity: CredentialIdentity
    /// nil explicitly means anonymous; certificates are never represented as an empty token.
    public let entry: CredentialCache.Entry?
    public var description: String { "AcquiredCredential (redacted)" }
    public var customMirror: Mirror { Mirror(self, children: ["contents": "redacted"]) }

    public init(identity: CredentialIdentity, entry: CredentialCache.Entry?) {
        self.identity = identity
        self.entry = entry
    }
}

public protocol CredentialProviding: Sendable {
    func acquire(for context: ResolvedContext, progress: @escaping AuthProgress) async throws -> AcquiredCredential
    func invalidate(_ identity: CredentialIdentity, failedGeneration: CredentialCache.Generation) async
}

public extension CredentialProviding {
    func acquire(for context: ResolvedContext) async throws -> AcquiredCredential {
        try await acquire(for: context, progress: { _ in })
    }
}
