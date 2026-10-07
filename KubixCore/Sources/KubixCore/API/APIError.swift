import Foundation

public struct KubernetesStatus: Codable, Equatable, Sendable {
    // The streaming remote-command encoder may omit TypeMeta and code.
    public let apiVersion: String?
    public let kind: String?
    public let status: String?
    public let reason: String?
    public let message: String?
    public let code: Int?
    public let details: KubernetesStatusDetails?
}

public struct KubernetesStatusDetails: Codable, Equatable, Sendable {
    public let name: String?
    public let group: String?
    public let kind: String?
    public let uid: String?
    public let causes: [KubernetesStatusCause]?
    public let retryAfterSeconds: Int?
}

public struct KubernetesStatusCause: Codable, Equatable, Sendable {
    public let reason: String?
    public let message: String?
    public let field: String?
}

public enum TransportFailure: String, Sendable {
    case connection, invalidResponse, timedOut, upgradeTimedOut, pingFailed, pongTimedOut
    case closed, nonBinaryMessage, streamReadInProgress
    case upgradeResponseUnavailable, receiveBufferOverflow, receiveInProgress
}

public enum TLSFailure: String, Sendable {
    case invalidCertificateAuthority, certificateAuthorityUnavailable, trustEvaluationFailed
}

public enum APIError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case status(KubernetesStatus, httpCode: Int, resource: String)
    case http(code: Int, resource: String)
    case transport(TransportFailure)
    case tls(TLSFailure)
    case unsupportedProtocol
    case invalidRequest
    case snapshot(SnapshotFailure)
    case podAuthentication
    indirect case watch(WatchFailure)
    /// Receipt only, never the credential itself; used by a long-lived watch's retry owner.
    indirect case credentialRejected(APIError, identity: CredentialIdentity, generation: CredentialCache.Generation, owner: UUID? = nil)
    indirect case retryAfter(APIError, delay: TimeInterval)
    /// The authenticated transport already retried this 401 with refreshed credentials.
    indirect case credentialsExhausted(APIError)

    public static func response(
        code: Int, body: Data, resource: String, redacting token: String? = nil,
        retryAfter: String? = nil, now: Date = Date()
    ) -> Self {
        let error = bodyError(code: code, body: body, resource: resource, redacting: token)
        if let delay = RetryAfter.delay(retryAfter, now: now) { return .retryAfter(error, delay: delay) }
        return error
    }

    private static func bodyError(code: Int, body: Data, resource: String, redacting token: String?) -> Self {
        // Error pages are untrusted; never retain HTML, oversized bodies, or credential echoes.
        if body.count <= 65_536, let decoded = try? JSONDecoder().decode(KubernetesStatus.self, from: body),
           decoded.apiVersion == "v1", decoded.kind == "Status" {
            func safe(_ value: String?) -> String? {
                value.map { text in
                    let cleaned = token.map { text.replacingOccurrences(of: $0, with: "[redacted]") } ?? text
                    return String(cleaned.prefix(4_096))
                }
            }
            let status = KubernetesStatus(
                apiVersion: "v1", kind: "Status", status: safe(decoded.status), reason: safe(decoded.reason),
                message: safe(decoded.message), code: decoded.code,
                details: decoded.details?.retryAfterSeconds.flatMap { delay in
                    guard delay >= 0 else { return nil }
                    return KubernetesStatusDetails(
                        name: nil, group: nil, kind: nil, uid: nil, causes: nil, retryAfterSeconds: delay
                    )
                }
            )
            return .status(status, httpCode: code, resource: resource)
        }
        return .http(code: code, resource: resource)
    }

    public var httpCode: Int? {
        switch self {
        case .status(_, let code, _), .http(let code, _): code
        case .retryAfter(let error, _), .credentialsExhausted(let error), .credentialRejected(let error, _, _, _): error.httpCode
        default: nil
        }
    }

    public var kubernetesStatus: KubernetesStatus? {
        switch self {
        case .status(let status, _, _): status
        case .retryAfter(let error, _), .credentialsExhausted(let error), .credentialRejected(let error, _, _, _): error.kubernetesStatus
        default: nil
        }
    }

    public var retryAfterDelay: TimeInterval? {
        switch self {
        case .retryAfter(let error, let delay): max(delay, error.retryAfterDelay ?? 0)
        case .credentialsExhausted(let error): error.retryAfterDelay
        case .credentialRejected(let error, _, _, _): error.retryAfterDelay
        case .status(let status, _, _): status.details?.retryAfterSeconds.flatMap { $0 >= 0 ? TimeInterval($0) : nil }
        default: nil
        }
    }

    public var credentialRefreshExhausted: Bool {
        switch self {
        case .credentialsExhausted: true
        case .retryAfter(let error, _): error.credentialRefreshExhausted
        case .credentialRejected(let error, _, _, _): error.credentialRefreshExhausted
        default: false
        }
    }

    public var description: String {
        switch self {
        case .status(let status, let code, let resource):
            "\(status.reason ?? "HTTP \(code)"): \(resource)" + (status.message.map { " — " + $0 } ?? "")
        case .http(let code, let resource): "HTTP \(code): \(resource) (no Kubernetes Status body)"
        case .tls(let failure): "TLS failure: \(failure.rawValue). Check the cluster CA and server hostname."
        case .transport(.upgradeResponseUnavailable):
            "WebSocket upgrade failed. Foundation did not expose an HTTP response; no authentication retry was attempted."
        case .transport(let failure): "Transport failure: \(failure.rawValue)"
        case .unsupportedProtocol: "Exec requires negotiated v5.channel.k8s.io. Check server and intermediary support."
        case .invalidRequest: "Invalid Kubernetes server URL, resource path, or request options."
        case .snapshot(let failure): "Invalid pod list snapshot: \(failure.rawValue). Refresh to retry."
        case .podAuthentication: "Pod authentication failed. Check authentication settings and explicitly retry."
        case .watch(let failure): "Pod watch stopped: \(failure). Refresh to retry."
        case .credentialRejected(let error, _, _, _): error.description
        case .retryAfter(let error, _): error.description
        case .credentialsExhausted(let error): error.description + " Credential refresh was exhausted."
        }
    }

    public var errorDescription: String? { description }
}
