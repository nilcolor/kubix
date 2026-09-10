import Foundation

public extension APIError {
    /// Watch errors have no credential available for redaction. Retain only protocol diagnostics,
    /// as HTTP handling does for retry metadata, never arbitrary server text or Status details.
    static func watchStatus(_ status: KubernetesStatus) -> APIError {
        let reasons = [
            "Unauthorized": 401, "Forbidden": 403, "NotFound": 404, "AlreadyExists": 409,
            "Conflict": 409, "Gone": 410, "Expired": 410, "Invalid": 422, "BadRequest": 400,
            "TooManyRequests": 429, "InternalError": 500, "ServiceUnavailable": 503,
            "Timeout": 504, "ServerTimeout": 504, "MethodNotAllowed": 405,
            "NotAcceptable": 406, "RequestEntityTooLarge": 413, "UnsupportedMediaType": 415,
        ]
        let reason = status.reason.flatMap { reasons[$0] == nil ? nil : $0 }
        let code = status.code ?? reason.flatMap { reasons[$0] } ?? 0
        let delay = status.details?.retryAfterSeconds.flatMap { $0 >= 0 ? $0 : nil }
        let safe = KubernetesStatus(
            apiVersion: "v1", kind: "Status", status: nil, reason: reason, message: nil, code: code,
            details: delay.map {
                KubernetesStatusDetails(name: nil, group: nil, kind: nil, uid: nil, causes: nil, retryAfterSeconds: $0)
            }
        )
        return .status(safe, httpCode: code, resource: "pods watch")
    }
}
