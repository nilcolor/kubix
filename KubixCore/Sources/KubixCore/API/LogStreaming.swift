import Foundation

public struct LogTarget: Equatable, Sendable {
    public let context: ResolvedContext
    public let namespace: String
    public let pod: String
    public let uid: String
    public let container: PodDetails.Container

    public init(context: ResolvedContext, details: PodDetails, container: PodDetails.Container) {
        self.context = context
        namespace = details.namespace
        pod = details.name
        uid = details.uid
        self.container = container
    }
}

public enum LogEvent: Sendable {
    case opened
    case lines([DecodedLogLine])
}

public enum LogOutcome: Equatable, Sendable {
    case completed, cancelled
    case interrupted(LogFailure)
    case failed(LogFailure)
}

/// Payload-free diagnostics: neither server Status messages nor log bytes are retained in errors.
public enum LogFailure: Equatable, Sendable {
    case forbidden, deleted, notReady, replaced, invalidTarget, authentication, transport, deadline, overflow, unavailable
    case server(Int)

    public var diagnostic: String {
        switch self {
        case .forbidden: "Forbidden: logs require get-pods and get-pods/log permission."
        case .deleted: "This pod or its logs are no longer available."
        case .notReady: "Container logs are not available yet, or the requested previous instance does not exist (400)."
        case .replaced: "The pod was replaced. This session will never adopt a different Pod UID."
        case .invalidTarget: "The original pod/container is no longer an eligible log target."
        case .authentication: "Authentication failed. Sign in or retry using the shared authentication controls, then Resume."
        case .transport: "Log transport interrupted. Retained lines are preserved; Resume starts a new tail."
        case .deadline: "Log idle/resource deadline reached. Retained lines are preserved; Resume starts a new tail."
        case .overflow: "Log transport exceeded the bounded chunk limit. Resume starts a new tail."
        case .unavailable: "Select the original context and namespace before resuming this session."
        case .server(let code): "Log request failed (HTTP \(code)). Resume explicitly to retry."
        }
    }

    public static func classify(_ error: any Error) -> Self {
        if let error = error as? PodDetailsError {
            return error == .replaced ? .replaced : .invalidTarget
        }
        guard let error = error as? APIError else { return .authentication }
        if let code = error.httpCode { return http(code) }
        switch error {
        case .transport(.timedOut): return .deadline
        case .transport(.receiveBufferOverflow): return .overflow
        case .invalidRequest: return .invalidTarget
        default: return .transport
        }
    }

    private static func http(_ code: Int) -> Self {
        switch code {
        case 400: .notReady
        case 401: .authentication
        case 403: .forbidden
        case 404: .deleted
        default: .server(code)
        }
    }
}

/// Pull IO and awaited delivery provide backpressure; no unbounded event stream or replay queue.
public protocol LogStreaming: Sendable {
    func run(
        target: LogTarget, request: LogRequest,
        receive: @escaping @MainActor @Sendable (LogEvent) -> Void
    ) async -> LogOutcome
}
