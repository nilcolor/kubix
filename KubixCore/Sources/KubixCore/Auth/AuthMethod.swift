import Foundation

public enum AuthMethod: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    case token(String)
    case tokenFile(String)
    case exec(KubeconfigExec)
    case clientCertificate(certificate: CertificateAuthoritySource, key: CertificateAuthoritySource)
    case anonymous

    public var description: String { "AuthMethod (contents redacted)" }
    public var customMirror: Mirror { Mirror(self, children: ["contents": "redacted"]) }

    /// Nonempty token > tokenFile > exec > certificate/key > anonymous.
    /// Inline certificate/key data wins over its respective file. Empty fields are absent;
    /// a selected but invalid method fails rather than falling back to weaker authentication.
    /// Selection performs no IO and only accepts contexts that passed the activation gate.
    public static func resolve(from context: ResolvedContext) throws -> AuthMethod {
        guard let user = context.user else { return .anonymous }
        if let token = nonempty(user.token) {
            _ = try Credential(token: token)
            return .token(token)
        }
        if let path = nonempty(user.tokenFile) { return .tokenFile(path) }
        if let configuration = user.exec {
            _ = try ExecCredential.validate(configuration)
            return .exec(configuration)
        }
        let certificate = material(data: user.clientCertificateData, path: user.clientCertificate)
        let key = material(data: user.clientKeyData, path: user.clientKey)
        guard certificate != nil || key != nil else { return .anonymous }
        guard let certificate, let key else { throw AuthError.incompleteClientCertificate }
        return .clientCertificate(certificate: certificate, key: key)
    }

    private static func material(data: String?, path: String?) -> CertificateAuthoritySource? {
        if let data = nonempty(data) { return .inlineData(data) }
        return nonempty(path).map(CertificateAuthoritySource.file)
    }
}

func nonempty(_ value: String?) -> String? {
    value.flatMap { $0.isEmpty ? nil : $0 }
}

/// Fixed diagnostics never include plugin stdout, configuration, paths, or credential material.
public enum AuthError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case invalidConfiguration
    case execAuthenticationRequired
    case invalidExecCommand
    case unsupportedAPIVersion
    case missingInteractiveMode
    case invalidInteractiveMode
    case interactiveInputRequired
    case missingClusterCertificateAuthority
    case malformedExecCredential
    case invalidExecCredentialKind
    case outputVersionMismatch
    case missingCredentials
    case invalidToken
    case incompleteClientCertificate
    case invalidClientCertificate
    case invalidExpiration
    case expiredCredential

    public var description: String {
        switch self {
        case .invalidConfiguration:
            "The authentication configuration could not be encoded."
        case .execAuthenticationRequired:
            "An ExecCredential request requires the selected authentication method to be exec."
        case .invalidExecCommand:
            "The exec plugin command must not be empty."
        case .unsupportedAPIVersion:
            "Exec authentication requires client.authentication.k8s.io/v1 or v1beta1."
        case .missingInteractiveMode:
            "Exec authentication v1 requires interactiveMode: Never or IfAvailable."
        case .invalidInteractiveMode:
            "Exec interactiveMode must be Never, IfAvailable, or Always."
        case .interactiveInputRequired:
            "This plugin requires terminal stdin, which is unsupported. Browser sign-in does not require stdin."
        case .missingClusterCertificateAuthority:
            "Load the configured cluster CA file before providing cluster information to the exec plugin."
        case .malformedExecCredential:
            "The exec plugin returned malformed credential JSON or invalid field types."
        case .invalidExecCredentialKind:
            "The exec plugin response kind must be ExecCredential."
        case .outputVersionMismatch:
            "The exec plugin response apiVersion must match the configured request version."
        case .missingCredentials:
            "The exec plugin must return a nonempty token or a complete certificate/key pair."
        case .invalidToken:
            "A bearer token must contain only non-whitespace printable ASCII characters."
        case .incompleteClientCertificate:
            "Client certificate authentication requires both certificate and key material."
        case .invalidClientCertificate:
            "Client certificate and key material must not be blank."
        case .invalidExpiration:
            "The credential expirationTimestamp must be a valid RFC3339 timestamp."
        case .expiredCredential:
            "The acquired credential has already expired."
        }
    }

    public var errorDescription: String? { description }
}
