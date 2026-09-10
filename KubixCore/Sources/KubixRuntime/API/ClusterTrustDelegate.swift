import Foundation
import KubixCore
import Security

/// Immutable and shared by all purpose-specific sessions, including task-level WebSocket delegates.
public final class ClusterTrustPolicy: @unchecked Sendable {
    public let insecureSkipTLSVerify: Bool
    public let serverName: String?
    public let anchors: [SecCertificate]
    public var warning: String? {
        insecureSkipTLSVerify ? "WARNING: TLS certificate and hostname verification are DISABLED for this context." : nil
    }

    public init(cluster: KubeconfigCluster, authorityData: Data?) throws {
        if let proxy = cluster.proxyURL, !proxy.isEmpty { throw KubeconfigError.unsupportedProxy }
        insecureSkipTLSVerify = cluster.insecureSkipTLSVerify == true
        serverName = cluster.tlsServerName
        anchors = try authorityData.map(Self.certificates) ?? []
        if (cluster.certificateAuthority != nil || cluster.certificateAuthorityData != nil) && authorityData == nil {
            throw APIError.tls(.invalidCertificateAuthority)
        }
    }

    public static func load(
        cluster: KubeconfigCluster, materials: any AuthMaterialReading
    ) async throws -> ClusterTrustPolicy {
        if let proxy = cluster.proxyURL, !proxy.isEmpty { throw KubeconfigError.unsupportedProxy }
        var data: Data?
        if let encoded = cluster.certificateAuthorityData {
            guard !encoded.isEmpty, let decoded = Data(base64Encoded: encoded) else {
                throw APIError.tls(.invalidCertificateAuthority)
            }
            data = decoded
        } else if let path = cluster.certificateAuthority {
            guard !path.isEmpty else { throw APIError.tls(.invalidCertificateAuthority) }
            do { data = try await materials.read(path) } catch is CancellationError {
                throw CancellationError()
            } catch { throw APIError.tls(.certificateAuthorityUnavailable) }
        }
        return try ClusterTrustPolicy(cluster: cluster, authorityData: data)
    }

    public func evaluate(_ trust: SecTrust, hostname: String) -> Bool {
        if insecureSkipTLSVerify { return true }
        let policy = SecPolicyCreateSSL(true, (serverName ?? hostname) as CFString)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess else { return false }
        if !anchors.isEmpty {
            guard SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        }
        return SecTrustEvaluateWithError(trust, nil)
    }

    private static func certificates(_ data: Data) throws -> [SecCertificate] {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        guard let text = String(data: data, encoding: .utf8), text.contains(begin) else {
            guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
                throw APIError.tls(.invalidCertificateAuthority)
            }
            return [certificate]
        }
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var certificates: [SecCertificate] = []
        while !remaining.isEmpty {
            guard remaining.hasPrefix(begin), let boundary = remaining.range(of: end) else {
                throw APIError.tls(.invalidCertificateAuthority)
            }
            let base64 = remaining.dropFirst(begin.count)[..<boundary.lowerBound]
                .filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: String(base64)),
                  let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                throw APIError.tls(.invalidCertificateAuthority)
            }
            certificates.append(certificate)
            remaining = String(remaining[boundary.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !certificates.isEmpty else { throw APIError.tls(.invalidCertificateAuthority) }
        return certificates
    }
}

public class ClusterTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    public let policy: ClusterTrustPolicy
    private let failureLock = NSLock()
    private var failure: (any Error)?
    public var authenticationFailure: (any Error)? { failureLock.withLock { failure } }
    public init(policy: ClusterTrustPolicy) { self.policy = policy }

    public func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        answer(challenge, completionHandler: completionHandler)
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        answer(challenge, completionHandler: completionHandler)
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Never forward a bearer credential to a redirect target, even within the same host.
        completionHandler(nil)
    }

    private func answer(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            if let trust = challenge.protectionSpace.serverTrust,
               policy.evaluate(trust, hostname: challenge.protectionSpace.host) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                failureLock.withLock { failure = APIError.tls(.trustEvaluationFailed) }
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodClientCertificate:
            // Identity import, including certificate-returning exec plugins, is Task 19.
            failureLock.withLock { failure = AuthenticationError.unsupportedCertificate }
            completionHandler(.cancelAuthenticationChallenge, nil)
        default: completionHandler(.performDefaultHandling, nil)
        }
    }
}
