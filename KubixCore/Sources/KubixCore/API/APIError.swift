import Foundation

public struct KubernetesStatus: Codable, Equatable, Sendable {
    public let apiVersion: String
    public let kind: String
    public let reason: String?
    public let message: String?
    public let code: Int?
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

    public static func response(
        code: Int, body: Data, resource: String, redacting token: String? = nil
    ) -> Self {
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
                apiVersion: "v1", kind: "Status", reason: safe(decoded.reason),
                message: safe(decoded.message), code: decoded.code
            )
            return .status(status, httpCode: code, resource: resource)
        }
        return .http(code: code, resource: resource)
    }

    public var httpCode: Int? {
        switch self {
        case .status(_, let code, _), .http(let code, _): code
        default: nil
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
        case .invalidRequest: "Invalid Kubernetes server URL or resource path."
        }
    }

    public var errorDescription: String? { description }
}
