import Foundation

public struct Kubeconfig: Codable, Equatable, Sendable, CustomStringConvertible {
    public var apiVersion: String?
    public var kind: String?
    public var currentContext: String?
    public var clusters: [NamedCluster]
    public var contexts: [NamedContext]
    public var users: [NamedUser]

    public var description: String { "Kubeconfig (contents redacted)" }

    public init(
        apiVersion: String? = nil, kind: String? = nil, currentContext: String? = nil,
        clusters: [NamedCluster] = [], contexts: [NamedContext] = [], users: [NamedUser] = []
    ) {
        self.apiVersion = apiVersion
        self.kind = kind
        self.currentContext = currentContext
        self.clusters = clusters
        self.contexts = contexts
        self.users = users
    }

    enum CodingKeys: String, CodingKey {
        case apiVersion, kind, clusters, contexts, users
        case currentContext = "current-context"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try values.decodeIfPresent(String.self, forKey: .apiVersion)
        kind = try values.decodeIfPresent(String.self, forKey: .kind)
        currentContext = try values.decodeIfPresent(String.self, forKey: .currentContext)
        clusters = try values.decodeIfPresent([NamedCluster].self, forKey: .clusters) ?? []
        contexts = try values.decodeIfPresent([NamedContext].self, forKey: .contexts) ?? []
        users = try values.decodeIfPresent([NamedUser].self, forKey: .users) ?? []
    }

    /// This is the activation gate. Credential acquisition and transport creation must use its result.
    public func resolve(context name: String? = nil) throws -> ResolvedContext {
        guard let selectedName = name ?? currentContext, !selectedName.isEmpty else {
            throw KubeconfigError.missingCurrentContext
        }
        guard let selected = contexts.first(where: { $0.name == selectedName }) else {
            throw KubeconfigError.unknownContext
        }
        guard let clusterName = selected.context.cluster, !clusterName.isEmpty else {
            throw KubeconfigError.missingClusterReference
        }
        guard let cluster = clusters.first(where: { $0.name == clusterName }) else {
            throw KubeconfigError.unknownCluster
        }
        // Check before user resolution, auth, or any CA/credential file access.
        if let proxy = cluster.cluster.proxyURL, !proxy.isEmpty {
            throw KubeconfigError.unsupportedProxy
        }
        guard let server = URLComponents(string: cluster.cluster.server),
              ["https", "http"].contains(server.scheme?.lowercased() ?? ""),
              let host = server.host, !host.isEmpty,
              server.user == nil, server.password == nil, server.url != nil else {
            throw KubeconfigError.invalidServer
        }
        var user: NamedUser?
        if let userName = selected.context.user, !userName.isEmpty {
            guard let match = users.first(where: { $0.name == userName }) else {
                throw KubeconfigError.unknownUser
            }
            user = match
        }
        let namespace = selected.context.namespace.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        return ResolvedContext(
            name: selected.name, namespace: namespace, cluster: cluster, user: user,
            sourceFile: selected.sourceFile
        )
    }
}

public struct NamedCluster: Codable, Equatable, Sendable, CustomStringConvertible {
    public var name: String
    public var cluster: KubeconfigCluster
    public internal(set) var sourceFile: URL?
    public var description: String { "NamedCluster (contents redacted)" }

    public init(name: String, cluster: KubeconfigCluster) {
        self.name = name
        self.cluster = cluster
    }

    enum CodingKeys: String, CodingKey { case name, cluster }
}

public struct KubeconfigCluster: Codable, Equatable, Sendable, CustomStringConvertible {
    public var server: String
    public var certificateAuthority: String?
    public var certificateAuthorityData: String?
    public var insecureSkipTLSVerify: Bool?
    public var proxyURL: String?
    public var tlsServerName: String?
    public var disableCompression: Bool?
    public var description: String { "KubeconfigCluster (contents redacted)" }

    public init(
        server: String, certificateAuthority: String? = nil, certificateAuthorityData: String? = nil,
        insecureSkipTLSVerify: Bool? = nil, proxyURL: String? = nil,
        tlsServerName: String? = nil, disableCompression: Bool? = nil
    ) {
        self.server = server
        self.certificateAuthority = certificateAuthority
        self.certificateAuthorityData = certificateAuthorityData
        self.insecureSkipTLSVerify = insecureSkipTLSVerify
        self.proxyURL = proxyURL
        self.tlsServerName = tlsServerName
        self.disableCompression = disableCompression
    }

    /// Inline CA data takes precedence; selection never reads a file or decodes certificate material.
    public var certificateAuthoritySource: CertificateAuthoritySource? {
        if let data = certificateAuthorityData, !data.isEmpty { return .inlineData(data) }
        if let path = certificateAuthority, !path.isEmpty { return .file(path) }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case server
        case certificateAuthority = "certificate-authority"
        case certificateAuthorityData = "certificate-authority-data"
        case insecureSkipTLSVerify = "insecure-skip-tls-verify"
        case proxyURL = "proxy-url"
        case tlsServerName = "tls-server-name"
        case disableCompression = "disable-compression"
    }
}

public enum CertificateAuthoritySource: Equatable, Sendable, CustomStringConvertible {
    case inlineData(String)
    case file(String)

    public var description: String { "CertificateAuthoritySource (contents redacted)" }
}

public struct NamedContext: Codable, Equatable, Sendable, CustomStringConvertible {
    public var name: String
    public var context: KubeconfigContext
    public internal(set) var sourceFile: URL?
    public var description: String { "NamedContext (contents redacted)" }

    public init(name: String, context: KubeconfigContext) {
        self.name = name
        self.context = context
    }

    enum CodingKeys: String, CodingKey { case name, context }
}

public struct KubeconfigContext: Codable, Equatable, Sendable, CustomStringConvertible {
    public var cluster: String?
    public var user: String?
    public var namespace: String?
    public var description: String { "KubeconfigContext (contents redacted)" }

    public init(cluster: String? = nil, user: String? = nil, namespace: String? = nil) {
        self.cluster = cluster
        self.user = user
        self.namespace = namespace
    }
}

public struct NamedUser: Codable, Equatable, Sendable, CustomStringConvertible {
    public var name: String
    public var user: KubeconfigUser
    public internal(set) var sourceFile: URL?
    public var description: String { "NamedUser (contents redacted)" }

    public init(name: String, user: KubeconfigUser) {
        self.name = name
        self.user = user
    }

    enum CodingKeys: String, CodingKey { case name, user }
}

public struct KubeconfigUser: Codable, Equatable, Sendable, CustomStringConvertible {
    public var token: String?
    public var tokenFile: String?
    public var exec: KubeconfigExec?
    public var clientCertificate: String?
    public var clientCertificateData: String?
    public var clientKey: String?
    public var clientKeyData: String?
    public var description: String { "KubeconfigUser (contents redacted)" }

    public init(
        token: String? = nil, tokenFile: String? = nil, exec: KubeconfigExec? = nil,
        clientCertificate: String? = nil, clientCertificateData: String? = nil,
        clientKey: String? = nil, clientKeyData: String? = nil
    ) {
        self.token = token
        self.tokenFile = tokenFile
        self.exec = exec
        self.clientCertificate = clientCertificate
        self.clientCertificateData = clientCertificateData
        self.clientKey = clientKey
        self.clientKeyData = clientKeyData
    }

    enum CodingKeys: String, CodingKey {
        case token, tokenFile, exec
        case clientCertificate = "client-certificate"
        case clientCertificateData = "client-certificate-data"
        case clientKey = "client-key"
        case clientKeyData = "client-key-data"
    }
}

public struct KubeconfigExec: Codable, Equatable, Sendable, CustomStringConvertible {
    public var apiVersion: String?
    public var command: String
    public var args: [String]?
    public var env: [ExecEnvironmentVariable]?
    public var interactiveMode: String?
    public var installHint: String?
    public var provideClusterInfo: Bool?
    public var description: String { "KubeconfigExec (contents redacted)" }

    public init(
        command: String, apiVersion: String? = nil, args: [String]? = nil,
        env: [ExecEnvironmentVariable]? = nil, interactiveMode: String? = nil,
        installHint: String? = nil, provideClusterInfo: Bool? = nil
    ) {
        self.command = command
        self.apiVersion = apiVersion
        self.args = args
        self.env = env
        self.interactiveMode = interactiveMode
        self.installHint = installHint
        self.provideClusterInfo = provideClusterInfo
    }
}

public struct ExecEnvironmentVariable: Codable, Equatable, Sendable, CustomStringConvertible {
    public var name: String
    public var value: String
    public var description: String { "ExecEnvironmentVariable (contents redacted)" }

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Only `Kubeconfig.resolve` can construct an activated context; its cluster cannot bypass the proxy gate.
public struct ResolvedContext: Equatable, Sendable, CustomStringConvertible {
    public let name: String
    public let namespace: String
    public let clusterName: String
    public let cluster: KubeconfigCluster
    public let userName: String?
    public let user: KubeconfigUser?
    public let sourceFile: URL?
    public let clusterSourceFile: URL?
    public let userSourceFile: URL?
    public var description: String { "ResolvedContext (contents redacted)" }

    fileprivate init(name: String, namespace: String, cluster: NamedCluster, user: NamedUser?, sourceFile: URL?) {
        self.name = name
        self.namespace = namespace
        clusterName = cluster.name
        self.cluster = cluster.cluster
        userName = user?.name
        self.user = user?.user
        self.sourceFile = sourceFile
        clusterSourceFile = cluster.sourceFile
        userSourceFile = user?.sourceFile
    }
}
