import Foundation
import KubixCore
import Testing

func authConfiguration(
    user: KubeconfigUser? = KubeconfigUser(token: "synthetic-token"),
    cluster: KubeconfigCluster = KubeconfigCluster(server: "https://synthetic.invalid"),
    name: String = "shared-display-name", namespace: String = "default"
) -> Kubeconfig {
    Kubeconfig(
        currentContext: name,
        clusters: [NamedCluster(name: "cluster", cluster: cluster)],
        contexts: [NamedContext(name: name, context: KubeconfigContext(
            cluster: "cluster", user: user == nil ? nil : "user", namespace: namespace
        ))],
        users: user.map { [NamedUser(name: "user", user: $0)] } ?? []
    )
}

func authContext(
    user: KubeconfigUser? = KubeconfigUser(token: "synthetic-token"),
    cluster: KubeconfigCluster = KubeconfigCluster(server: "https://synthetic.invalid")
) throws -> ResolvedContext {
    try authConfiguration(user: user, cluster: cluster).resolve()
}

func authExec(
    version: ExecCredential.APIVersion = .v1, mode: String? = "Never", clusterInfo: Bool? = nil
) -> KubeconfigExec {
    KubeconfigExec(
        command: "synthetic-plugin", apiVersion: version.rawValue, args: ["synthetic-argument"],
        env: [ExecEnvironmentVariable(name: "SYNTHETIC_ENV", value: "synthetic-environment-secret")],
        interactiveMode: mode, provideClusterInfo: clusterInfo
    )
}

@Test func authPrecedenceAndSelectionDoNotAcquireMaterial() throws {
    var user = KubeconfigUser(
        token: "synthetic-token", tokenFile: "/synthetic/missing-token", exec: authExec(),
        clientCertificate: "/synthetic/missing-cert", clientKey: "/synthetic/missing-key"
    )
    #expect(try AuthMethod.resolve(from: authContext(user: user)) == .token("synthetic-token"))
    user.token = ""
    #expect(try AuthMethod.resolve(from: authContext(user: user)) == .tokenFile("/synthetic/missing-token"))
    user.tokenFile = ""
    #expect(try AuthMethod.resolve(from: authContext(user: user)) == .exec(authExec()))
    user.exec = nil
    #expect(try AuthMethod.resolve(from: authContext(user: user)) == .clientCertificate(
        certificate: .file("/synthetic/missing-cert"), key: .file("/synthetic/missing-key")
    ))
    user.clientCertificateData = "synthetic-inline-cert"
    user.clientKeyData = "synthetic-inline-key"
    #expect(try AuthMethod.resolve(from: authContext(user: user)) == .clientCertificate(
        certificate: .inlineData("synthetic-inline-cert"), key: .inlineData("synthetic-inline-key")
    ))
    user.clientKeyData = ""
    #expect(try AuthMethod.resolve(from: authContext(user: user)) == .clientCertificate(
        certificate: .inlineData("synthetic-inline-cert"), key: .file("/synthetic/missing-key")
    ))
}

@Test(arguments: [nil, KubeconfigUser(), KubeconfigUser(
    token: "", tokenFile: "", clientCertificate: "", clientCertificateData: "", clientKey: "", clientKeyData: ""
)])
func authAbsentAndEmptyFieldsAreAnonymous(user: KubeconfigUser?) throws {
    #expect(try AuthMethod.resolve(from: authContext(user: user)) == .anonymous)
}

@Test(arguments: [
    KubeconfigUser(clientCertificate: "/synthetic/cert"),
    KubeconfigUser(clientKey: "/synthetic/key"),
    KubeconfigUser(clientCertificateData: "synthetic-cert", clientKeyData: ""),
    KubeconfigUser(clientKeyData: "synthetic-key"),
])
func authIncompleteStaticCertificateFails(user: KubeconfigUser) throws {
    let context = try authContext(user: user)
    #expect(throws: AuthError.incompleteClientCertificate) { try AuthMethod.resolve(from: context) }
}

@Test func authInvalidSelectedMethodDoesNotFallBack() throws {
    let invalidExec = KubeconfigExec(command: "")
    var user = KubeconfigUser(token: "synthetic-token", exec: invalidExec, clientCertificate: "incomplete")
    #expect(try AuthMethod.resolve(from: authContext(user: user)) == .token("synthetic-token"))
    user.token = " \n"
    let invalidToken = try authContext(user: user)
    #expect(throws: AuthError.invalidToken) { try AuthMethod.resolve(from: invalidToken) }
    user.token = nil
    user.tokenFile = "/synthetic/token"
    #expect(try AuthMethod.resolve(from: authContext(user: user)) == .tokenFile("/synthetic/token"))
    user.tokenFile = nil
    let invalidPlugin = try authContext(user: user)
    #expect(throws: AuthError.invalidExecCommand) { try AuthMethod.resolve(from: invalidPlugin) }
}

@Test func authProxyGatePrecedesInvalidAuth() {
    let config = authConfiguration(
        user: KubeconfigUser(exec: KubeconfigExec(command: "")),
        cluster: KubeconfigCluster(server: "https://synthetic.invalid", proxyURL: "http://synthetic-proxy.invalid")
    )
    #expect(throws: KubeconfigError.unsupportedProxy) { try AuthMethod.resolve(from: config.resolve()) }
}

@Test(arguments: [
    KubeconfigUser(token: "synthetic-token-2"), KubeconfigUser(tokenFile: "/synthetic/token"),
    KubeconfigUser(exec: authExec()), KubeconfigUser(clientCertificate: "cert", clientKey: "key"), nil,
])
func authIdentitySeparatesUsersWithSameContextName(user: KubeconfigUser?) throws {
    let original = try authContext()
    let changed = try authContext(user: user)
    #expect(original.name == changed.name)
    #expect(try CredentialIdentity(from: original) != CredentialIdentity(from: changed))
}

@Test(arguments: [
    KubeconfigCluster(server: "https://different.invalid"),
    KubeconfigCluster(server: "https://synthetic.invalid", certificateAuthority: "/synthetic/ca"),
    KubeconfigCluster(server: "https://synthetic.invalid", certificateAuthorityData: "synthetic-ca"),
    KubeconfigCluster(server: "https://synthetic.invalid", insecureSkipTLSVerify: true),
    KubeconfigCluster(server: "https://synthetic.invalid", tlsServerName: "different.invalid"),
    KubeconfigCluster(server: "https://synthetic.invalid", disableCompression: true),
])
func authIdentitySeparatesClusterAndTLSChanges(cluster: KubeconfigCluster) throws {
    #expect(try CredentialIdentity(from: authContext()) != CredentialIdentity(from: authContext(cluster: cluster)))
}

@Test func authIdentityIncludesAllPluginConfiguration() throws {
    let baseline = authExec()
    let identity = try CredentialIdentity(from: authContext(user: KubeconfigUser(exec: baseline)))
    var variants = [KubeconfigExec]()
    var changed = baseline
    changed.command = "/synthetic/other-plugin"
    variants.append(changed)
    changed = baseline
    changed.args = ["different-argument"]
    variants.append(changed)
    changed = baseline
    changed.env = [ExecEnvironmentVariable(name: "SYNTHETIC_ENV", value: "different-secret")]
    variants.append(changed)
    changed = baseline
    changed.apiVersion = ExecCredential.APIVersion.v1beta1.rawValue
    variants.append(changed)
    changed = baseline
    changed.interactiveMode = "IfAvailable"
    variants.append(changed)
    changed = baseline
    changed.provideClusterInfo = true
    variants.append(changed)
    changed = baseline
    changed.installHint = "different-install-hint"
    variants.append(changed)
    for variant in variants {
        #expect(try CredentialIdentity(from: authContext(user: KubeconfigUser(exec: variant))) != identity)
    }
}

@Test func authIdentityEqualityIgnoresDisplayNameAndNamespace() throws {
    let original = try CredentialIdentity(from: authContext())
    let renamed = try CredentialIdentity(from: authConfiguration(name: "renamed", namespace: "different").resolve())
    #expect(original == renamed)
    #expect(Set([original, renamed]).count == 1)
    var otherUser = authConfiguration()
    otherUser.users[0].name = "other-user"
    otherUser.contexts[0].context.user = "other-user"
    #expect(try CredentialIdentity(from: otherUser.resolve()) != original)
    var otherCluster = authConfiguration()
    otherCluster.clusters[0].name = "other-cluster"
    otherCluster.contexts[0].context.cluster = "other-cluster"
    #expect(try CredentialIdentity(from: otherCluster.resolve()) != original)
}

@Test func authIdentityPreservesFileProvenance() throws {
    struct Files: KubeconfigFileSystem {
        let data: Data
        func readFile(at url: URL) throws -> Data? { data }
    }
    let files = Files(data: try JSONEncoder().encode(authConfiguration()))
    let identities = try ["one", "two"].map { name in
        let config = try KubeconfigLoader(
            environment: ["KUBECONFIG": name],
            homeDirectory: URL(fileURLWithPath: "/synthetic/home"),
            workingDirectory: URL(fileURLWithPath: "/synthetic/work"), fileSystem: files
        ).load()
        return try CredentialIdentity(from: config.resolve())
    }
    #expect(identities[0] != identities[1])
}

@Test func authMaterialAndConfigurationAreRedactedInDescriptionsAndReflection() throws {
    let context = try authContext(user: KubeconfigUser(exec: authExec(clusterInfo: true)))
    let credential = try Credential(
        token: "synthetic-secret-token", clientCertificateData: "synthetic-secret-cert", clientKeyData: "synthetic-secret-key"
    )
    let request = try ExecCredential.Request(from: context)
    let values: [Any] = [
        try AuthMethod.resolve(from: context), credential, try CredentialIdentity(from: context),
        request, request.spec, try #require(request.spec.cluster),
    ]
    for value in values {
        var dumped = ""
        dump(value, to: &dumped)
        let text = "\(value) \(String(reflecting: value)) \(dumped)"
        #expect(text.contains("redacted"))
        #expect(!text.contains("synthetic"))
    }
    #expect(credential.token == "synthetic-secret-token")
    #expect(credential.clientCertificateData == "synthetic-secret-cert")
    #expect(credential.clientKeyData == "synthetic-secret-key")
}

@Test(arguments: [
    AuthError.invalidConfiguration, .execAuthenticationRequired, .invalidExecCommand, .unsupportedAPIVersion,
    .missingInteractiveMode, .invalidInteractiveMode, .interactiveInputRequired, .missingClusterCertificateAuthority,
    .malformedExecCredential, .invalidExecCredentialKind, .outputVersionMismatch, .missingCredentials, .invalidToken,
    .incompleteClientCertificate, .invalidClientCertificate, .invalidExpiration, .expiredCredential,
])
func authErrorsAreActionableAndSanitized(error: AuthError) {
    #expect(error.localizedDescription == error.description)
    #expect(!error.description.isEmpty)
    #expect(!error.description.contains("synthetic"))
}
