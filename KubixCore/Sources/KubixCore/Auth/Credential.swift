import Foundation

/// In-memory material only. PEM parsing and identity import belong to the later certificate path.
/// A plugin may return both bearer and TLS credentials; neither is silently discarded.
public struct Credential: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let token: String?
    public let clientCertificateData: String?
    public let clientKeyData: String?
    public let expirationTimestamp: Date?

    public var description: String { "Credential (contents redacted)" }
    public var customMirror: Mirror { Mirror(self, children: ["contents": "redacted"]) }

    public init(
        token: String? = nil, clientCertificateData: String? = nil,
        clientKeyData: String? = nil, expirationTimestamp: Date? = nil
    ) throws {
        let token = nonempty(token)
        let certificate = nonempty(clientCertificateData)
        let key = nonempty(clientKeyData)
        if let token, !token.utf8.allSatisfy({ (33...126).contains($0) }) {
            throw AuthError.invalidToken
        }
        guard (certificate == nil) == (key == nil) else { throw AuthError.incompleteClientCertificate }
        if let certificate, let key {
            guard !certificate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AuthError.invalidClientCertificate
            }
        }
        guard token != nil || certificate != nil else { throw AuthError.missingCredentials }
        if let expirationTimestamp, !expirationTimestamp.timeIntervalSince1970.isFinite {
            throw AuthError.invalidExpiration
        }
        self.token = token
        self.clientCertificateData = certificate
        self.clientKeyData = key
        self.expirationTimestamp = expirationTimestamp
    }
}

/// An opaque, process-local equality key, not a display name or a persistable/loggable fingerprint.
/// Canonical bytes give exact equality (no digest collision risk); they remain private and redacted,
/// including reflection. The cache owner must discard identities and credentials on process exit.
public struct CredentialIdentity: Hashable, Sendable, CustomStringConvertible, CustomReflectable {
    private let configuration: Data

    public var description: String { "CredentialIdentity (redacted)" }
    public var customMirror: Mirror { Mirror(self, children: ["contents": "redacted"]) }

    /// Namespace and context display name do not affect auth. Include all cluster/user configuration
    /// and their provenance, so changing tokens, TLS policy, plugin arguments/environment, or source
    /// files cannot reuse credentials merely because the context has the same name.
    public init(from context: ResolvedContext) throws {
        let snapshot = IdentityConfiguration(
            clusterName: context.clusterName, cluster: context.cluster, clusterSource: context.clusterSourceFile,
            userName: context.userName, user: context.user, userSource: context.userSourceFile
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            configuration = try encoder.encode(snapshot)
        } catch {
            throw AuthError.invalidConfiguration
        }
    }
}

private struct IdentityConfiguration: Encodable {
    let clusterName: String
    let cluster: KubeconfigCluster
    let clusterSource: URL?
    let userName: String?
    let user: KubeconfigUser?
    let userSource: URL?
}
