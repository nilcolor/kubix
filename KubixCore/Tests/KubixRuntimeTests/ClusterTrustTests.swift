import Foundation
import KubixCore
@testable import KubixRuntime
import Security
import Testing

func syntheticCA() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "synthetic-ca", withExtension: "pem", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func syntheticTrust(certificate: SecCertificate) throws -> SecTrust {
    var trust: SecTrust?
    #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, nil), &trust) == errSecSuccess)
    let result = try #require(trust)
    #expect(SecTrustSetNetworkFetchAllowed(result, false) == errSecSuccess)
    // Fixed within the synthetic public certificate's 2026-09-10...2036-09-07 lifetime.
    #expect(SecTrustSetVerifyDate(result, Date(timeIntervalSince1970: 1_800_000_000) as CFDate) == errSecSuccess)
    return result
}

@Test func realSecurityTrustPinsCAAndChecksHostnameWithoutNetwork() throws {
    let cluster = KubeconfigCluster(server: "https://synthetic.invalid")
    let policy = try ClusterTrustPolicy(cluster: cluster, authorityData: syntheticCA())
    let leafURL = try #require(Bundle.module.url(forResource: "synthetic-server", withExtension: "pem", subdirectory: "Fixtures"))
    let leaf = try ClusterTrustPolicy(cluster: cluster, authorityData: Data(contentsOf: leafURL))
    let certificate = try #require(leaf.anchors.first)
    #expect(policy.anchors.count == 1)
    #expect(policy.warning == nil)
    #expect(policy.evaluate(try syntheticTrust(certificate: certificate), hostname: "synthetic.invalid"))
    #expect(!policy.evaluate(try syntheticTrust(certificate: certificate), hostname: "wrong.invalid"))
    let system = try ClusterTrustPolicy(cluster: cluster, authorityData: nil)
    #expect(system.anchors.isEmpty)
    #expect(!system.evaluate(try syntheticTrust(certificate: certificate), hostname: "synthetic.invalid"))
    let override = try ClusterTrustPolicy(
        cluster: KubeconfigCluster(server: "https://address.invalid", tlsServerName: "synthetic.invalid"), authorityData: syntheticCA()
    )
    #expect(override.evaluate(try syntheticTrust(certificate: certificate), hostname: "address.invalid"))
    let insecure = try ClusterTrustPolicy(
        cluster: KubeconfigCluster(server: "https://wrong.invalid", insecureSkipTLSVerify: true), authorityData: nil
    )
    #expect(insecure.warning?.contains("DISABLED") == true)
    #expect(insecure.evaluate(try syntheticTrust(certificate: certificate), hostname: "wrong.invalid"))
}

@Test func validPEMBundlesDERAndInlinePrecedence() async throws {
    let pem = try syntheticCA()
    let cluster = KubeconfigCluster(
        server: "https://synthetic.invalid", certificateAuthority: "/must-not-read", certificateAuthorityData: pem.base64EncodedString()
    )
    let materials = MaterialFiles()
    let policy = try await ClusterTrustPolicy.load(cluster: cluster, materials: materials)
    #expect(await materials.reads.isEmpty)
    let certificate = try #require(policy.anchors.first)
    let der = SecCertificateCopyData(certificate) as Data
    #expect(try ClusterTrustPolicy(cluster: cluster, authorityData: der).anchors.count == 1)
    #expect(try ClusterTrustPolicy(cluster: cluster, authorityData: pem + pem).anchors.count == 2)
    let fromFile = try await ClusterTrustPolicy.load(
        cluster: KubeconfigCluster(server: "https://synthetic.invalid", certificateAuthority: "/synthetic/ca"),
        materials: MaterialFiles(["/synthetic/ca": pem])
    )
    #expect(fromFile.anchors.count == 1)
}

@Test(arguments: ["", "not-base64", Data("not a certificate".utf8).base64EncodedString()])
func malformedCAFailsBeforeAuthOrIOEvenInInsecureMode(_ data: String) async throws {
    let credentials = TransportCredentials()
    let factory = RecordingSessionFactory()
    let config = transportConfiguration(cluster: KubeconfigCluster(
        server: "https://synthetic.invalid", certificateAuthorityData: data, insecureSkipTLSVerify: true
    ))
    await #expect(throws: APIError.tls(.invalidCertificateAuthority)) {
        try await URLSessionTransport.activate(configuration: config, credentials: credentials, factory: factory, warning: { _ in })
    }
    #expect(await credentials.acquisitions == 0)
    #expect(factory.policies.isEmpty)
}

@Test func malformedPEMBundleAndUnavailableCAFailClosed() async throws {
    let pem = try syntheticCA()
    let cluster = KubeconfigCluster(server: "https://synthetic.invalid")
    for invalid in [pem + Data("garbage".utf8), Data("garbage".utf8) + pem,
                    Data("-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----".utf8)] {
        #expect(throws: APIError.tls(.invalidCertificateAuthority)) {
            try ClusterTrustPolicy(cluster: cluster, authorityData: invalid)
        }
    }
    await #expect(throws: APIError.tls(.certificateAuthorityUnavailable)) {
        try await ClusterTrustPolicy.load(
            cluster: KubeconfigCluster(server: "https://synthetic.invalid", certificateAuthority: "/missing"),
            materials: MaterialFiles()
        )
    }
}

@Test(arguments: TransportPurpose.allCases)
func nativeSessionConfigurationsMatchPolicyAndCannotPersistCredentials(_ purpose: TransportPurpose) {
    let configuration = URLSessionFactory.configuration(for: purpose)
    let policy = TransportPolicy.policy(for: purpose)
    #expect(configuration.timeoutIntervalForRequest == policy.idleTimeout)
    #expect(configuration.tlsMinimumSupportedProtocolVersion == .TLSv12)
    #expect(configuration.timeoutIntervalForResource == policy.totalTimeout)
    #expect(configuration.urlCache == nil)
    #expect(configuration.urlCredentialStorage == nil)
    #expect(configuration.httpCookieStorage == nil)
    #expect(!configuration.httpShouldSetCookies)
}

@Test func nativeUpgradeErrorsOnlyRetryObservedStatusNeverGuessFromNSError() throws {
    let url = try #require(URL(string: "https://synthetic.invalid"))
    for code in [401, 403, 500] {
        let response = try #require(HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil))
        let failure = WebSocketUpgradeDelegate.failure(response: response, error: URLError(.badServerResponse))
        let handshake = try #require(failure as? WebSocketHandshakeError)
        #expect(handshake.statusCode == code)
        #expect(handshake.body.isEmpty)
    }
    #expect(WebSocketUpgradeDelegate.failure(response: nil, error: URLError(.badServerResponse)) as? APIError == .transport(.upgradeResponseUnavailable))
    #expect(WebSocketUpgradeDelegate.failure(response: nil, error: URLError(.serverCertificateUntrusted)) as? APIError == .tls(.trustEvaluationFailed))
    #expect(WebSocketUpgradeDelegate.failure(response: nil, error: URLError(.cannotConnectToHost)) as? APIError == .transport(.connection))
    #expect(WebSocketUpgradeDelegate.failure(response: nil, error: URLError(.cancelled)) is CancellationError)
}

@Test func delegateTracksOpenSoEstablishedFailuresCannotBecomeHandshake401() async throws {
    let policy = try ClusterTrustPolicy(cluster: KubeconfigCluster(server: "https://synthetic.invalid"), authorityData: nil)
    let delegate = WebSocketUpgradeDelegate(policy: policy)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.webSocketTask(with: try #require(URL(string: "wss://synthetic.invalid")))
    // No task is resumed; these are the real delegate callbacks with a dormant Foundation task.
    delegate.urlSession(session, webSocketTask: task, didOpenWithProtocol: "v5.channel.k8s.io")
    delegate.urlSession(session, task: task, didCompleteWithError: URLError(.badServerResponse))
    #expect(try await delegate.upgrade.value(cancel: {}) == "v5.channel.k8s.io")
}

private final class SyntheticChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

private final class SyntheticProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    let trust: SecTrust?
    override var serverTrust: SecTrust? { trust }
    init(method: String, trust: SecTrust? = nil) {
        self.trust = trust
        super.init(host: "wrong.invalid", port: 443, protocol: "https", realm: nil, authenticationMethod: method)
    }
    required init?(coder: NSCoder) { nil }
}

@Test(arguments: [NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodServerTrust])
func optionalClientCertificateDoesNotAbortBearerAuthButInvalidServerTrustFails(_ method: String) throws {
    let policy = try ClusterTrustPolicy(cluster: KubeconfigCluster(server: "https://synthetic.invalid"), authorityData: nil)
    let delegate = ClusterTrustDelegate(policy: policy)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let challenge = URLAuthenticationChallenge(
        protectionSpace: SyntheticProtectionSpace(method: method), proposedCredential: nil, previousFailureCount: 0,
        failureResponse: nil, error: nil, sender: SyntheticChallengeSender()
    )
    delegate.urlSession(session, didReceive: challenge) { disposition, credential in
        #expect(disposition == (method == NSURLAuthenticationMethodClientCertificate ? .performDefaultHandling : .cancelAuthenticationChallenge))
        #expect(credential == nil)
    }
    if method == NSURLAuthenticationMethodClientCertificate {
        #expect(delegate.authenticationFailure == nil)
    } else {
        #expect(delegate.authenticationFailure as? APIError == .tls(.trustEvaluationFailed))
    }
}

@Test func nativeDelegateRejectsRedirectWithoutForwardingBearerRequest() throws {
    let policy = try ClusterTrustPolicy(cluster: KubeconfigCluster(server: "https://synthetic.invalid"), authorityData: nil)
    let delegate = ClusterTrustDelegate(policy: policy)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let original = try #require(URL(string: "https://synthetic.invalid"))
    let task = session.dataTask(with: original)
    let response = try #require(HTTPURLResponse(url: original, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil))
    var redirect = URLRequest(url: try #require(URL(string: "https://other.invalid")))
    redirect.setValue("Bearer synthetic-token", forHTTPHeaderField: "Authorization")
    delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirect) { request in
        #expect(request == nil)
    }
}
