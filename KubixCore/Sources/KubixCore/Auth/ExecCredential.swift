import Foundation

public enum ExecCredential {
    public enum APIVersion: String, Codable, CaseIterable, Sendable {
        case v1 = "client.authentication.k8s.io/v1"
        case v1beta1 = "client.authentication.k8s.io/v1beta1"
    }

    public enum InteractiveMode: String, Sendable {
        case never = "Never"
        case ifAvailable = "IfAvailable"
        case always = "Always"

        public static func resolve(from configuration: KubeconfigExec) throws -> InteractiveMode {
            guard let version = configuration.apiVersion.flatMap(APIVersion.init(rawValue:)) else {
                throw AuthError.unsupportedAPIVersion
            }
            guard let rawMode = configuration.interactiveMode else {
                guard version == .v1beta1 else { throw AuthError.missingInteractiveMode }
                return .ifAvailable
            }
            guard let mode = InteractiveMode(rawValue: rawMode) else { throw AuthError.invalidInteractiveMode }
            return mode
        }
    }

    /// v0.1 never supplies interactive stdin, even when a plugin opens a browser.
    @discardableResult
    public static func validate(_ configuration: KubeconfigExec) throws -> APIVersion {
        guard !configuration.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AuthError.invalidExecCommand
        }
        guard let version = configuration.apiVersion.flatMap(APIVersion.init(rawValue:)) else {
            throw AuthError.unsupportedAPIVersion
        }
        guard try InteractiveMode.resolve(from: configuration) != .always else {
            throw AuthError.interactiveInputRequired
        }
        return version
    }

    public struct Request: Encodable, Equatable, Sendable, CustomStringConvertible, CustomReflectable {
        public let apiVersion: APIVersion
        public let kind = "ExecCredential"
        public let spec: Spec
        public var description: String { "ExecCredential.Request (contents redacted)" }
        public var customMirror: Mirror { Mirror(self, children: ["contents": "redacted"]) }

        /// The caller supplies CA file bytes only when requested; this model never reads files.
        /// Inline kubeconfig CA data takes precedence over those bytes.
        public init(from context: ResolvedContext, certificateAuthorityFileData: Data? = nil) throws {
            guard case .exec(let configuration) = try AuthMethod.resolve(from: context) else {
                throw AuthError.execAuthenticationRequired
            }
            apiVersion = try ExecCredential.validate(configuration)
            let cluster = configuration.provideClusterInfo == true
                ? try Cluster(from: context.cluster, certificateAuthorityFileData: certificateAuthorityFileData) : nil
            spec = Spec(interactive: false, cluster: cluster)
        }

        /// Intended exclusively for KUBERNETES_EXEC_INFO, never progress text or logs.
        public func encoded() throws -> Data {
            do { return try JSONEncoder().encode(self) } catch { throw AuthError.invalidConfiguration }
        }
    }

    public struct Spec: Encodable, Equatable, Sendable, CustomStringConvertible, CustomReflectable {
        public let interactive: Bool
        public let cluster: Cluster?
        public var description: String { "ExecCredential.Spec (contents redacted)" }
        public var customMirror: Mirror { Mirror(self, children: ["contents": "redacted"]) }
    }

    public struct Cluster: Encodable, Equatable, Sendable, CustomStringConvertible, CustomReflectable {
        public let server: String
        public let tlsServerName: String?
        public let insecureSkipTLSVerify: Bool?
        public let certificateAuthorityData: String?
        public let disableCompression: Bool?
        public var description: String { "ExecCredential.Cluster (contents redacted)" }
        public var customMirror: Mirror { Mirror(self, children: ["contents": "redacted"]) }

        fileprivate init(from cluster: KubeconfigCluster, certificateAuthorityFileData: Data?) throws {
            server = cluster.server
            tlsServerName = cluster.tlsServerName
            insecureSkipTLSVerify = cluster.insecureSkipTLSVerify
            disableCompression = cluster.disableCompression
            switch cluster.certificateAuthoritySource {
            case .inlineData(let data):
                certificateAuthorityData = data
            case .file:
                guard let data = certificateAuthorityFileData else { throw AuthError.missingClusterCertificateAuthority }
                certificateAuthorityData = data.base64EncodedString()
            case nil:
                certificateAuthorityData = nil
            }
        }

        enum CodingKeys: String, CodingKey {
            case server
            case tlsServerName = "tls-server-name"
            case insecureSkipTLSVerify = "insecure-skip-tls-verify"
            case certificateAuthorityData = "certificate-authority-data"
            case disableCompression = "disable-compression"
        }
    }

    public struct Response: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
        public let apiVersion: APIVersion
        public let credential: Credential
        public var description: String { "ExecCredential.Response (contents redacted)" }
        public var customMirror: Mirror { Mirror(self, children: ["contents": "redacted"]) }

        public init(data: Data, expectedVersion: APIVersion) throws {
            let output: ExecCredentialOutput
            do { output = try JSONDecoder().decode(ExecCredentialOutput.self, from: data) } catch {
                throw AuthError.malformedExecCredential
            }
            guard output.kind == "ExecCredential" else { throw AuthError.invalidExecCredentialKind }
            guard let version = APIVersion(rawValue: output.apiVersion) else { throw AuthError.unsupportedAPIVersion }
            guard version == expectedVersion else { throw AuthError.outputVersionMismatch }
            guard let status = output.status else { throw AuthError.missingCredentials }
            apiVersion = version
            credential = try Credential(
                token: status.token, clientCertificateData: status.clientCertificateData,
                clientKeyData: status.clientKeyData,
                expirationTimestamp: try status.expirationTimestamp.map(parseExpiration)
            )
        }
    }
}

private struct ExecCredentialOutput: Decodable {
    let apiVersion: String
    let kind: String
    let status: ExecCredentialStatus?
}

private struct ExecCredentialStatus: Decodable {
    let token: String?
    let clientCertificateData: String?
    let clientKeyData: String?
    let expirationTimestamp: String?
}

private func parseExpiration(_ value: String) throws -> Date {
    guard let date = RFC3339.date(from: value) else { throw AuthError.invalidExpiration }
    return date
}
