import Foundation
import KubixCore
import Testing

private func execFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: "execcredential-\(name)", withExtension: "json", subdirectory: "Fixtures"
    ))
    return try Data(contentsOf: url)
}

private func execResponse(
    status: [String: Any]? = ["token": "synthetic-token"],
    version: String = ExecCredential.APIVersion.v1.rawValue, kind: String = "ExecCredential"
) throws -> ExecCredential.Response {
    var object: [String: Any] = ["apiVersion": version, "kind": kind]
    object["status"] = status
    return try ExecCredential.Response(data: JSONSerialization.data(withJSONObject: object), expectedVersion: .v1)
}

@Test(arguments: ExecCredential.APIVersion.allCases, ["Never", "IfAvailable"])
func execRequestAlwaysDeclaresNoninteractiveInput(version: ExecCredential.APIVersion, mode: String) throws {
    let configuration = authExec(version: version, mode: mode)
    let request = try ExecCredential.Request(from: authContext(user: KubeconfigUser(exec: configuration)))
    #expect(request.apiVersion == version)
    #expect(request.kind == "ExecCredential")
    #expect(!request.spec.interactive)
    #expect(request.spec.cluster == nil)
    let json = try #require(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
    #expect(json["apiVersion"] as? String == version.rawValue)
    #expect(json["kind"] as? String == "ExecCredential")
    let spec = try #require(json["spec"] as? [String: Any])
    #expect(spec["interactive"] as? Bool == false)
    #expect(spec["cluster"] == nil)
    #expect(json["status"] == nil)
    #expect(json.count == 3)
}

@Test func execInteractionModeDefaultIsOnlyForBeta() throws {
    let beta = authExec(version: .v1beta1, mode: nil)
    #expect(try ExecCredential.InteractiveMode.resolve(from: beta) == .ifAvailable)
    #expect(try !ExecCredential.Request(from: authContext(user: KubeconfigUser(exec: beta))).spec.interactive)
    let v1 = authExec(mode: nil)
    #expect(throws: AuthError.missingInteractiveMode) { try ExecCredential.validate(v1) }
}

@Test(arguments: ExecCredential.APIVersion.allCases)
func execAlwaysRequiresUnsupportedTerminalInput(version: ExecCredential.APIVersion) throws {
    let configuration = authExec(version: version, mode: "Always")
    #expect(try ExecCredential.InteractiveMode.resolve(from: configuration) == .always)
    #expect(throws: AuthError.interactiveInputRequired) { try ExecCredential.validate(configuration) }
    let context = try authContext(user: KubeconfigUser(exec: configuration))
    #expect(throws: AuthError.interactiveInputRequired) { try ExecCredential.Request(from: context) }
}

@Test(arguments: ExecCredential.APIVersion.allCases, ["", "never", "sometimes", " Never"])
func execInvalidInteractionModesFail(version: ExecCredential.APIVersion, mode: String) {
    #expect(throws: AuthError.invalidInteractiveMode) { try ExecCredential.validate(authExec(version: version, mode: mode)) }
}

@Test(arguments: [nil, "", "v1", "client.authentication.k8s.io/v2", "synthetic-secret-version"])
func execInvalidConfiguredVersionsFail(version: String?) {
    var configuration = authExec()
    configuration.apiVersion = version
    #expect(throws: AuthError.unsupportedAPIVersion) { try ExecCredential.validate(configuration) }
    #expect(throws: AuthError.unsupportedAPIVersion) {
        try ExecCredential.InteractiveMode.resolve(from: configuration)
    }
}

@Test(arguments: ["", " ", "\n"])
func execEmptyCommandsFail(command: String) {
    var configuration = authExec()
    configuration.command = command
    #expect(throws: AuthError.invalidExecCommand) { try ExecCredential.validate(configuration) }
}

@Test func execRequestHonorsMethodPrecedence() throws {
    let context = try authContext(user: KubeconfigUser(token: "synthetic-token", exec: authExec()))
    #expect(throws: AuthError.execAuthenticationRequired) { try ExecCredential.Request(from: context) }
}

@Test func execClusterInformationUsesWireKeysAndInlineCAPrecedence() throws {
    let cluster = KubeconfigCluster(
        server: "https://synthetic.invalid:6443", certificateAuthority: "/synthetic/missing-ca",
        certificateAuthorityData: "c3ludGhldGljLWNh", insecureSkipTLSVerify: false,
        tlsServerName: "synthetic-tls.invalid", disableCompression: true
    )
    let context = try authContext(user: KubeconfigUser(exec: authExec(clusterInfo: true)), cluster: cluster)
    let request = try ExecCredential.Request(from: context, certificateAuthorityFileData: Data("ignored".utf8))
    let json = try #require(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
    let spec = try #require(json["spec"] as? [String: Any])
    let info = try #require(spec["cluster"] as? [String: Any])
    #expect(info["server"] as? String == cluster.server)
    #expect(info["tls-server-name"] as? String == cluster.tlsServerName)
    #expect(info["insecure-skip-tls-verify"] as? Bool == false)
    #expect(info["disable-compression"] as? Bool == true)
    #expect(info["certificate-authority-data"] as? String == "c3ludGhldGljLWNh")
    #expect(info["certificate-authority"] == nil)
    #expect(info["proxy-url"] == nil)
    #expect(info.count == 5)
    #expect(String(decoding: try request.encoded(), as: UTF8.self).contains("synthetic-environment-secret") == false)
}

@Test func execCAFileRequiresInjectedBytesOnlyWhenClusterInfoRequested() throws {
    let cluster = KubeconfigCluster(server: "https://synthetic.invalid", certificateAuthority: "/synthetic/missing-ca")
    let context = try authContext(user: KubeconfigUser(exec: authExec(clusterInfo: true)), cluster: cluster)
    #expect(throws: AuthError.missingClusterCertificateAuthority) { try ExecCredential.Request(from: context) }
    let data = Data("synthetic-file-ca".utf8)
    #expect(try ExecCredential.Request(from: context, certificateAuthorityFileData: data)
        .spec.cluster?.certificateAuthorityData == data.base64EncodedString())
    for flag in [nil, false] {
        let omitted = try authContext(user: KubeconfigUser(exec: authExec(clusterInfo: flag)), cluster: cluster)
        #expect(try ExecCredential.Request(from: omitted).spec.cluster == nil)
    }
    let noCA = try authContext(user: KubeconfigUser(exec: authExec(clusterInfo: true)))
    #expect(try ExecCredential.Request(from: noCA).spec.cluster?.certificateAuthorityData == nil)
}

@Test func execDecodesV1TokenAndBetaWithoutExpiry() throws {
    let v1 = try ExecCredential.Response(data: execFixture("v1-token"), expectedVersion: .v1)
    #expect(v1.apiVersion == .v1)
    #expect(v1.credential.token == "synthetic-v1-token")
    #expect(v1.credential.expirationTimestamp == Date(timeIntervalSince1970: 1_893_553_445))
    #expect(v1.credential.clientCertificateData == nil)
    let beta = try ExecCredential.Response(data: execFixture("v1beta1-token"), expectedVersion: .v1beta1)
    #expect(beta.apiVersion == .v1beta1)
    #expect(beta.credential.token == "synthetic-beta-token")
    #expect(beta.credential.expirationTimestamp == nil)
}

@Test func execPreservesCertificateAndCombinedResultsWithoutImportingPEM() throws {
    let certificate = try ExecCredential.Response(data: execFixture("v1-certificate"), expectedVersion: .v1).credential
    #expect(certificate.token == nil)
    #expect(certificate.clientCertificateData?.contains("synthetic-certificate-not-valid-PEM") == true)
    #expect(certificate.clientKeyData?.contains("synthetic-key-not-valid-PEM") == true)
    #expect(certificate.expirationTimestamp == Date(timeIntervalSince1970: 1_893_553_445.125))
    let combined = try ExecCredential.Response(data: execFixture("v1beta1-combined"), expectedVersion: .v1beta1)
    #expect(combined.credential.token == "synthetic-combined-token")
    #expect(combined.credential.clientCertificateData == "synthetic-certificate")
    #expect(combined.credential.clientKeyData == "synthetic-key")
    #expect(combined.credential.expirationTimestamp == nil)
    var dumped = ""
    dump(combined, to: &dumped)
    #expect(!"\(combined) \(String(reflecting: combined)) \(dumped)".contains("synthetic"))
}

@Test(arguments: ExecCredential.APIVersion.allCases)
func execOutputVersionMustMatchExactly(expected: ExecCredential.APIVersion) throws {
    let fixtureName = expected == .v1 ? "v1beta1-token" : "v1-token"
    let data = try execFixture(fixtureName)
    #expect(throws: AuthError.outputVersionMismatch) { try ExecCredential.Response(data: data, expectedVersion: expected) }
}

@Test func execOutputRejectsUnsupportedVersionAndKind() {
    #expect(throws: AuthError.unsupportedAPIVersion) { try execResponse(version: "synthetic-secret-version") }
    #expect(throws: AuthError.invalidExecCredentialKind) { try execResponse(kind: "synthetic-secret-kind") }
}

@Test(arguments: [
    "", "synthetic-secret-stdout", "{}", "[]", "null",
    #"{"apiVersion":1,"kind":"ExecCredential"}"#,
    #"{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"token":3}}"#,
    #"{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"expirationTimestamp":3}}"#,
    #"{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"clientKeyData":[]}}"#,
    #"{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":[]}"#,
])
func execMalformedOutputIsSanitized(json: String) {
    #expect(throws: AuthError.malformedExecCredential) {
        try ExecCredential.Response(data: Data(json.utf8), expectedVersion: .v1)
    }
}

@Test func execEmptyStatusAndCredentialsFail() {
    for status: [String: Any]? in [nil, [:], ["token": ""], ["token": NSNull()],
                                  ["clientCertificateData": "", "clientKeyData": ""], ["expirationTimestamp": NSNull()]] {
        #expect(throws: AuthError.missingCredentials) { try execResponse(status: status) }
    }
}

@Test(arguments: [" ", "\n", "synthetic token", "synthetic\r\nHeader:value", "synthetic\u{0}", "synthetic\u{7f}", "tokén"])
func execUnusableTokensFail(token: String) {
    #expect(throws: AuthError.invalidToken) { try execResponse(status: ["token": token]) }
    #expect(throws: AuthError.invalidToken) { try Credential(token: token) }
}

@Test func execPartialCertificateFailsEvenWithUsableToken() {
    for status in [
        ["clientCertificateData": "synthetic-cert"], ["clientKeyData": "synthetic-key"],
        ["clientCertificateData": "", "clientKeyData": "synthetic-key"],
        ["clientCertificateData": "synthetic-cert", "clientKeyData": ""],
        ["token": "synthetic-token", "clientCertificateData": "synthetic-cert"],
    ] {
        #expect(throws: AuthError.incompleteClientCertificate) { try execResponse(status: status) }
    }
    #expect(throws: AuthError.invalidClientCertificate) {
        try execResponse(status: ["clientCertificateData": " \n", "clientKeyData": "synthetic-key"])
    }
    #expect(throws: AuthError.invalidClientCertificate) {
        try execResponse(status: ["clientCertificateData": "synthetic-cert", "clientKeyData": "\t"])
    }
}

@Test func execEmptyOptionalTokenCanAccompanyCertificate() throws {
    let response = try execResponse(status: [
        "token": "", "clientCertificateData": "synthetic-cert", "clientKeyData": "synthetic-key",
    ])
    #expect(response.credential.token == nil)
    #expect(response.credential.clientKeyData == "synthetic-key")
    #expect(try execResponse(status: ["token": "synthetic-token", "expirationTimestamp": NSNull()])
        .credential.expirationTimestamp == nil)
}

@Test(arguments: [
    "", "synthetic-secret-expiry", "2030-01-02", "2030-01-02T03:04:05", "2030-01-02T03:04:05Z trailing",
    "2030-13-02T03:04:05Z", "2030-02-30T03:04:05Z", "2030-01-02T25:04:05Z",
    "2030-02-29T03:04:05Z", "2030-01-02T03:60:05Z", "2030-01-02T03:04:60Z",
    "2030-01-02T03:04:05+25:00", "2030-01-02T03:04:05+01:60",
])
func execMalformedExpirationFails(expiration: String) {
    #expect(throws: AuthError.invalidExpiration) {
        try execResponse(status: ["token": "synthetic-token", "expirationTimestamp": expiration])
    }
}

@Test func execExpirationSupportsOffsetsFractionsAndPastDates() throws {
    let offset = try execResponse(status: [
        "token": "synthetic-token", "expirationTimestamp": "2030-01-02T04:04:05.125+01:00",
    ])
    #expect(offset.credential.expirationTimestamp == Date(timeIntervalSince1970: 1_893_553_445.125))
    let past = try execResponse(status: ["token": "synthetic-token", "expirationTimestamp": "2000-01-01T00:00:00Z"])
    #expect(past.credential.expirationTimestamp == Date(timeIntervalSince1970: 946_684_800))
    let leapDay = try execResponse(status: ["token": "synthetic-token", "expirationTimestamp": "2032-02-29T00:00:00Z"])
    #expect(leapDay.credential.expirationTimestamp != nil)
}

@Test(arguments: [TimeInterval.infinity, -.infinity, .nan])
func credentialRejectsNonfiniteExpiration(value: TimeInterval) {
    #expect(throws: AuthError.invalidExpiration) {
        try Credential(token: "synthetic-token", expirationTimestamp: Date(timeIntervalSince1970: value))
    }
}
