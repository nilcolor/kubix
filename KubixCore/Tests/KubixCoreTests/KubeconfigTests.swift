import Foundation
import KubixCore
import Testing
import Yams

private let syntheticHome = URL(fileURLWithPath: "/synthetic/home", isDirectory: true)
private let syntheticWork = URL(fileURLWithPath: "/synthetic/work", isDirectory: true)

// The lock protects the read log; all fixture data is immutable.
private final class FixtureFileSystem: KubeconfigFileSystem, @unchecked Sendable {
    private let files: [String: Data]
    private let lock = NSLock()
    private var reads: [String] = []
    private let deniedPath: String?

    init(_ files: [String: Data] = [:], deniedPath: String? = nil) {
        self.files = files
        self.deniedPath = deniedPath
    }

    var readPaths: [String] { lock.withLock { reads } }

    func readFile(at url: URL) throws -> Data? {
        lock.withLock { reads.append(url.path) }
        if url.path == deniedPath {
            throw NSError(domain: "synthetic-secret-filesystem-error", code: 1)
        }
        return files[url.path]
    }
}

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}

private func fixtureURL(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: "kubeconfig-\(name)", withExtension: "yaml", subdirectory: "Fixtures"))
}

private func loader(_ files: FixtureFileSystem, paths: String? = "config") -> KubeconfigLoader {
    KubeconfigLoader(
        environment: paths.map { ["KUBECONFIG": $0] } ?? [:],
        homeDirectory: syntheticHome, workingDirectory: syntheticWork, fileSystem: files
    )
}

private func loadFixture(_ name: String = "token") throws -> Kubeconfig {
    try loader(FixtureFileSystem(["/synthetic/work/config": fixture(name)])).load()
}

@Test func kubeconfigSingleFileAndInlineCA() throws {
    let files = FixtureFileSystem(["/synthetic/work/config": try fixture("token")])
    let config = try loader(files).load()
    let resolved = try config.resolve()
    #expect(config.apiVersion == "v1")
    #expect(config.kind == "Config")
    #expect(config.currentContext == "development")
    #expect(resolved.name == "development")
    #expect(resolved.namespace == "sandbox")
    #expect(resolved.clusterName == "local")
    #expect(resolved.userName == "developer")
    #expect(resolved.cluster.server == "https://cluster.invalid:6443")
    #expect(resolved.cluster.certificateAuthority == "/synthetic/work/pki/ca.pem")
    #expect(resolved.cluster.certificateAuthoritySource == .inlineData("c3ludGhldGljLWNh"))
    #expect(resolved.cluster.insecureSkipTLSVerify == false)
    #expect(resolved.cluster.proxyURL == "")
    #expect(resolved.cluster.tlsServerName == "cluster.invalid")
    #expect(resolved.cluster.disableCompression == true)
    #expect(resolved.user?.token == "synthetic-token-not-a-credential")
    #expect(resolved.user?.tokenFile == "/synthetic/work/tokens/current")
    #expect(resolved.sourceFile?.path == "/synthetic/work/config")
    #expect(resolved.clusterSourceFile == resolved.sourceFile)
    #expect(resolved.userSourceFile == resolved.sourceFile)
    #expect(files.readPaths == ["/synthetic/work/config"])
}

@Test func kubeconfigMergeIsFirstWinsWithIndependentProvenance() throws {
    let first = "/synthetic/work/configs/one"
    let second = "/synthetic/home/configs/two"
    let files = FixtureFileSystem([
        first: try fixture("merge-first"), second: try fixture("merge-second"),
        "/synthetic/home/.kube/config": try fixture("token"),
    ])
    let config = try loader(files, paths: ":configs/one:~/configs/two::configs/one:/missing:").load()
    #expect(files.readPaths == [first, second, "/missing"])
    #expect(config.currentContext == "shared")
    #expect(config.clusters.map(\.name) == ["shared", "second"])
    #expect(config.users.map(\.name) == ["shared", "second"])
    #expect(config.contexts.map(\.name) == ["shared", "cross-file", "mixed"])
    let shared = try config.resolve()
    #expect(shared.namespace == "default")
    #expect(shared.cluster.server == "https://first.invalid")
    #expect(shared.cluster.certificateAuthoritySource == .file("/synthetic/work/configs/first-ca.pem"))
    #expect(shared.cluster.certificateAuthorityData == nil)
    #expect(shared.cluster.proxyURL == nil)
    #expect(shared.user?.tokenFile == "/synthetic/work/configs/first-token")
    #expect(shared.user?.token == nil)
    #expect(shared.user?.exec == nil)
    let cross = try config.resolve(context: "cross-file")
    #expect(cross.namespace == "other")
    #expect(cross.sourceFile?.path == first)
    #expect(cross.clusterSourceFile?.path == second)
    #expect(cross.userSourceFile?.path == second)
    #expect(cross.cluster.certificateAuthority == "/synthetic/home/pki/second-ca.pem")
    #expect(cross.user?.tokenFile == "/synthetic/home/configs/tokens/second")
    #expect(cross.user?.clientCertificate == "/synthetic/home/configs/certs/second.pem")
    #expect(cross.user?.clientKey == "/synthetic/home/keys/second.pem")
    #expect(cross.user?.exec?.command == "/synthetic/home/plugins/test-auth")
    let mixed = try config.resolve(context: "mixed")
    #expect(mixed.sourceFile?.path == second)
    #expect(mixed.clusterSourceFile?.path == first)
    #expect(mixed.userSourceFile?.path == second)
    #expect(mixed.cluster.certificateAuthority == shared.cluster.certificateAuthority)
    #expect(mixed.user == cross.user)
}

@Test(arguments: [nil, ""])
func kubeconfigDefaultPathUsesInjectedHome(paths: String?) throws {
    let files = FixtureFileSystem(["/synthetic/home/.kube/config": try fixture("token")])
    let config = try loader(files, paths: paths).load()
    #expect(files.readPaths == ["/synthetic/home/.kube/config"])
    #expect(try config.resolve().user?.tokenFile == "/synthetic/home/.kube/tokens/current")
}

@Test(arguments: [nil, "", ":", "/missing"])
func kubeconfigAbsentFilesAreReportedWithoutDefaultFallback(paths: String?) {
    #expect(throws: KubeconfigError.configurationNotFound) {
        try loader(FixtureFileSystem(), paths: paths).load()
    }
}

@Test(arguments: [":", "/missing"])
func kubeconfigExplicitListNeverFallsBackToDefault(paths: String) throws {
    let files = FixtureFileSystem(["/synthetic/home/.kube/config": try fixture("token")])
    #expect(throws: KubeconfigError.configurationNotFound) { try loader(files, paths: paths).load() }
    #expect(!files.readPaths.contains("/synthetic/home/.kube/config"))
}

@Test func kubeconfigEmptyCurrentContextYieldsToLaterFile() throws {
    let files = FixtureFileSystem([
        "/synthetic/work/empty": Data("current-context: ''\nclusters: null\n".utf8),
        "/synthetic/work/config": try fixture("token"),
    ])
    #expect(try loader(files, paths: "empty:config").load().resolve().name == "development")
}

@Test(arguments: ["", "# empty config\n", "{}\n", "null\n", "clusters: null\ncontexts: []\nusers: null\n"])
func kubeconfigEmptyDocumentsHaveEmptyCollections(yaml: String) throws {
    let files = FixtureFileSystem(["/synthetic/work/config": Data(yaml.utf8)])
    let config = try loader(files).load()
    #expect(config.clusters.isEmpty && config.contexts.isEmpty && config.users.isEmpty)
    #expect(throws: KubeconfigError.missingCurrentContext) { try config.resolve() }
}

@Test func kubeconfigExecAndCertificateFieldsArePreservedWithoutAuth() throws {
    let config = try loadFixture("exec")
    let resolved = try config.resolve()
    let exec = try #require(resolved.user?.exec)
    #expect(exec.apiVersion == "client.authentication.k8s.io/v1")
    #expect(exec.command == "/synthetic/work/plugins/test-auth")
    #expect(exec.args == ["get-token", "--profile", "synthetic profile", "$(not-a-shell-command)"])
    #expect(exec.env == [
        ExecEnvironmentVariable(name: "SYNTHETIC_SECRET", value: "synthetic-env-not-a-credential"),
        ExecEnvironmentVariable(name: "PATH", value: "/synthetic/tools"),
    ])
    #expect(exec.interactiveMode == "Never")
    #expect(exec.installHint == "Install the synthetic test plugin.")
    #expect(exec.provideClusterInfo == true)
    #expect(resolved.cluster.insecureSkipTLSVerify == true)
    #expect(resolved.cluster.certificateAuthoritySource == .file("/synthetic/home/certificates/ca.pem"))
    let certificate = try config.resolve(context: "certificate")
    #expect(certificate.user?.clientCertificate == "/synthetic/work/certs/client.pem")
    #expect(certificate.user?.clientCertificateData == "c3ludGhldGljLWNlcnQ=")
    #expect(certificate.user?.clientKey == "/synthetic/home/keys/client.pem")
    #expect(certificate.user?.clientKeyData == "c3ludGhldGljLWtleQ==")
}

@Test(arguments: [
    ("aws", "aws"), ("shim", "shim"), ("./plugin", "/synthetic/work/plugin"),
    ("plugins/auth", "/synthetic/work/plugins/auth"), ("../auth", "/synthetic/auth"),
    ("/opt/synthetic/auth", "/opt/synthetic/auth"), ("~/bin/auth", "/synthetic/home/bin/auth"),
    ("./plugin with spaces", "/synthetic/work/plugin with spaces"),
])
func kubeconfigExecPathResolution(command: String, expected: String) throws {
    var config = try loadFixture("exec")
    config.users[0].user.exec?.command = command
    let yaml = try YAMLEncoder().encode(config)
    let files = FixtureFileSystem(["/synthetic/work/config": Data(yaml.utf8)])
    #expect(try loader(files).load().resolve().user?.exec?.command == expected)
    #expect(files.readPaths == ["/synthetic/work/config"])
}

@Test(arguments: ["~/material", "relative/material", "/absolute/material", "", "~"])
func kubeconfigEveryFileFieldResolvesWithoutReadingMaterial(path: String) throws {
    let expected = [
        "~/material": "/synthetic/home/material",
        "relative/material": "/synthetic/work/relative/material",
        "/absolute/material": "/absolute/material", "": "", "~": "/synthetic/home",
    ][path]
    var config = try loadFixture()
    config.clusters[0].cluster.certificateAuthority = path
    config.users[0].user.tokenFile = path
    config.users[0].user.clientCertificate = path
    config.users[0].user.clientKey = path
    let files = FixtureFileSystem(["/synthetic/work/config": Data(try YAMLEncoder().encode(config).utf8)])
    let resolved = try loader(files).load().resolve()
    #expect(resolved.cluster.certificateAuthority == expected)
    #expect(resolved.user?.tokenFile == expected)
    #expect(resolved.user?.clientCertificate == expected)
    #expect(resolved.user?.clientKey == expected)
    #expect(files.readPaths == ["/synthetic/work/config"])
}

@Test func kubeconfigUnknownHomeIsNotLookedUp() {
    #expect(throws: KubeconfigError.unsupportedHomeReference) {
        try loader(FixtureFileSystem(), paths: "~someone/config").load()
    }
}

@Test(arguments: [nil, ""])
func kubeconfigMissingCurrentContextCanBeOverridden(current: String?) throws {
    var config = try loadFixture()
    config.currentContext = current
    #expect(throws: KubeconfigError.missingCurrentContext) { try config.resolve() }
    #expect(try config.resolve(context: "development").name == "development")
}

@Test func kubeconfigUnknownContextsAreRejected() throws {
    var config = try loadFixture()
    #expect(throws: KubeconfigError.unknownContext) { try config.resolve(context: "absent") }
    config.currentContext = "absent"
    #expect(throws: KubeconfigError.unknownContext) { try config.resolve() }
    #expect(try config.resolve(context: "development").name == "development")
}

@Test(arguments: [nil, "", "absent"])
func kubeconfigInvalidClusterReferencesAreRejected(reference: String?) throws {
    var config = try loadFixture()
    config.contexts[0].context.cluster = reference
    let error: KubeconfigError = reference == "absent" ? .unknownCluster : .missingClusterReference
    #expect(throws: error) { try config.resolve() }
}

@Test func kubeconfigUnknownUserIsNotAnonymous() throws {
    var config = try loadFixture()
    config.contexts[0].context.user = "absent"
    #expect(throws: KubeconfigError.unknownUser) { try config.resolve() }
}

@Test(arguments: [nil, ""])
func kubeconfigOmittedUserAndNamespaceHaveDefaults(value: String?) throws {
    var config = try loadFixture()
    config.contexts[0].context.user = value
    config.contexts[0].context.namespace = value
    let resolved = try config.resolve()
    #expect(resolved.user == nil && resolved.userName == nil && resolved.userSourceFile == nil)
    #expect(resolved.namespace == "default")
}

@Test(arguments: ["", "not a URL", "file:///secret", "https://", "https://name:synthetic-secret@cluster.invalid"])
func kubeconfigInvalidServersAreRejected(server: String) throws {
    var config = try loadFixture()
    config.clusters[0].cluster.server = server
    #expect(throws: KubeconfigError.invalidServer) { try config.resolve() }
}

@Test(arguments: ["http://proxy.invalid", "http://name:synthetic-secret@proxy.invalid", " ", "not a URL"])
func kubeconfigProxyGatePrecedesUserResolutionAndMaterialIO(proxy: String) throws {
    var config = try loadFixture("exec")
    config.clusters[0].cluster.proxyURL = proxy
    config.clusters[0].cluster.server = "invalid"
    config.contexts[0].context.user = "absent"
    let files = FixtureFileSystem(["/synthetic/work/config": Data(try YAMLEncoder().encode(config).utf8)])
    let loaded = try loader(files).load()
    #expect(loaded.clusters[0].cluster.proxyURL == proxy)
    #expect(throws: KubeconfigError.unsupportedProxy) { try loaded.resolve() }
    #expect(files.readPaths == ["/synthetic/work/config"])
}

@Test(arguments: [nil, ""])
func kubeconfigEmptyProxyIsSupported(proxy: String?) throws {
    var config = try loadFixture()
    config.clusters[0].cluster.proxyURL = proxy
    #expect(try config.resolve().name == "development")
}

@Test func kubeconfigMalformedYAMLErrorDoesNotExposeSource() throws {
    let files = FixtureFileSystem(["/synthetic/work/config": try fixture("malformed")])
    #expect(throws: KubeconfigError.malformedYAML) { try loader(files).load() }
    #expect(!KubeconfigError.malformedYAML.localizedDescription.contains("synthetic-secret"))
}

@Test(arguments: [
    "clusters: scalar", "users: [{name: test, user: {exec: {command: [invalid]}}}]",
    "clusters: [{name: test, cluster: {server: https://cluster.invalid, insecure-skip-tls-verify: invalid}}]",
    "contexts: [{context: {}}]",
])
func kubeconfigInvalidFieldTypesAreRejected(yaml: String) {
    let files = FixtureFileSystem(["/synthetic/work/config": Data(yaml.utf8)])
    #expect(throws: KubeconfigError.malformedYAML) { try loader(files).load() }
}

@Test(arguments: ["clusters", "contexts", "users"])
func kubeconfigInvalidEntryNamesAreRejected(collection: String) {
    let entry = [
        "clusters": "cluster: {server: https://cluster.invalid}", "contexts": "context: {}", "users": "user: {}",
    ][collection] ?? ""
    for yaml in [
        "\(collection): [{name: '', \(entry)}]",
        "\(collection): [{name: duplicate, \(entry)}, {name: duplicate, \(entry)}]",
    ] {
        let files = FixtureFileSystem(["/synthetic/work/config": Data(yaml.utf8)])
        #expect(throws: KubeconfigError.invalidEntryNames) { try loader(files).load() }
    }
}

@Test func kubeconfigUnreadableFileIsNotSilentlySkipped() throws {
    let files = FixtureFileSystem(["/synthetic/work/config": try fixture("token")], deniedPath: "/denied")
    #expect(throws: KubeconfigError.unreadableFile) { try loader(files, paths: "config:/denied").load() }
    #expect(!KubeconfigError.unreadableFile.localizedDescription.contains("synthetic-secret"))
}

@Test func kubeconfigLocalFileAdapterReadsOnlySyntheticFixtures() throws {
    let fileSystem = LocalKubeconfigFileSystem()
    let url = try fixtureURL("token")
    #expect(try fileSystem.readFile(at: url) == fixture("token"))
    let directory = url.deletingLastPathComponent()
    #expect(try fileSystem.readFile(at: directory.appendingPathComponent("absent-file")) == nil)
    #expect(throws: (any Error).self) { try fileSystem.readFile(at: directory) }
}

@Test(arguments: [
    "current-context: first\ncurrent-context: second",
    "clusters: [{name: test, cluster: {server: https://cluster.invalid, proxy-url: '', proxy-url: http://proxy.invalid}}]",
    "current-context: first\n---\ncurrent-context: second",
])
func kubeconfigAmbiguousYAMLIsRejected(yaml: String) {
    let files = FixtureFileSystem(["/synthetic/work/config": Data(yaml.utf8)])
    #expect(throws: KubeconfigError.malformedYAML) { try loader(files).load() }
}

@Test func kubeconfigProxyFromYAMLAnchorCannotBypassActivation() throws {
    let yaml = """
    proxy: &proxy http://proxy.invalid
    current-context: test
    contexts: [{name: test, context: {cluster: test}}]
    clusters: [{name: test, cluster: {server: https://cluster.invalid, proxy-url: *proxy}}]
    """
    let config = try loader(FixtureFileSystem(["/synthetic/work/config": Data(yaml.utf8)])).load()
    #expect(throws: KubeconfigError.unsupportedProxy) { try config.resolve() }
}

@Test func kubeconfigCASelectionHandlesEmptyInlineData() {
    var cluster = KubeconfigCluster(server: "https://cluster.invalid", certificateAuthority: "/synthetic/ca")
    #expect(cluster.certificateAuthoritySource == .file("/synthetic/ca"))
    cluster.certificateAuthorityData = ""
    #expect(cluster.certificateAuthoritySource == .file("/synthetic/ca"))
    cluster.certificateAuthority = ""
    #expect(cluster.certificateAuthoritySource == nil)
}

@Test(arguments: ["token", "exec", "merge-first", "merge-second"])
func kubeconfigCodableRoundTripsUseYAMLKeys(name: String) throws {
    let original = try YAMLDecoder().decode(Kubeconfig.self, from: fixture(name))
    let json = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(Kubeconfig.self, from: json) == original)
    #expect(try YAMLDecoder().decode(Kubeconfig.self, from: YAMLEncoder().encode(original)) == original)
    let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
    #expect(object["current-context"] as? String == original.currentContext)
    #expect(object["currentContext"] == nil)
}

@Test func kubeconfigProvenanceIsMetadataNotEncodedYAML() throws {
    let config = try loadFixture("exec")
    let json = try JSONEncoder().encode(config)
    #expect(!String(decoding: json, as: UTF8.self).contains("sourceFile"))
    let decoded = try JSONDecoder().decode(Kubeconfig.self, from: json)
    #expect(decoded.clusters[0].sourceFile == nil)
    #expect(decoded.contexts[0].sourceFile == nil)
    #expect(decoded.users[0].sourceFile == nil)
    #expect(decoded.users[0].user == config.users[0].user)
}

@Test func kubeconfigDescriptionsRedactNestedSecrets() throws {
    let config = try loadFixture("exec")
    let resolved = try config.resolve()
    let exec = try #require(resolved.user?.exec)
    let values: [any CustomStringConvertible] = [
        config, config.clusters[0], config.contexts[0], config.users[0], resolved,
        resolved.cluster, try #require(resolved.user), exec, try #require(exec.env?.first),
        try #require(resolved.cluster.certificateAuthoritySource),
        KubeconfigError.unsupportedProxy,
    ]
    for value in values {
        #expect(!String(describing: value).contains("synthetic"))
        #expect(!String(reflecting: value).contains("synthetic"))
    }
}
