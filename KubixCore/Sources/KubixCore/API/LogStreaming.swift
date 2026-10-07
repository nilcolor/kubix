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

    /// For a pod reached through its owner rather than its own details: a deployment names the
    /// container from its template, and the pod's name and UID come from the selector's list. The
    /// addressable shape is validated here, because nothing else on this path does it.
    public init(
        context: ResolvedContext, namespace: String, pod: String, uid: String, container: PodDetails.Container
    ) throws {
        _ = try LogRequest(namespace: namespace, pod: pod, container: container.name)
        guard !uid.isEmpty else { throw APIError.invalidRequest }
        self.context = context
        self.namespace = namespace
        self.pod = pod
        self.uid = uid
        self.container = container
    }
}

/// What one tab is following. A pod has one stream; a deployment has one per pod, because Kubernetes
/// has no aggregated log endpoint — `pods/{name}/log` is the only one there is, so every client that
/// shows a workload's logs fans out and interleaves them itself.
public enum LogSubject: Equatable, Sendable {
    case pod(name: String, uid: String)
    case deployment(name: String, uid: String)

    public var name: String {
        switch self {
        case .pod(let name, _), .deployment(let name, _): name
        }
    }

    /// The object this tab is bound to for its whole life. A pod session never adopts another pod's
    /// UID, and a deployment session never adopts another deployment's.
    public var uid: String {
        switch self {
        case .pod(_, let uid), .deployment(_, let uid): uid
        }
    }

    public var display: String {
        switch self {
        case .pod(let name, _): name
        case .deployment(let name, _): "deploy/" + name
        }
    }

    public var kind: ResourceKind {
        switch self {
        case .pod: .pods
        case .deployment: .deployments
        }
    }
}

/// A tab's immutable identity: what it follows, where, and in which container. The container is the
/// one the user chose; for a deployment it names a container of the pod template, which every pod
/// the deployment owns declares.
public struct LogScope: Equatable, Sendable {
    public let context: ResolvedContext
    public let namespace: String
    public let subject: LogSubject
    public let container: PodDetails.Container

    public init(context: ResolvedContext, namespace: String, subject: LogSubject, container: PodDetails.Container) {
        self.context = context
        self.namespace = namespace
        self.subject = subject
        self.container = container
    }
}

/// One stream inside a tab: a pod, a container, and how that stream is doing. A pod session has
/// exactly one, so there is one lifecycle rather than two.
public struct LogSource: Identifiable, Equatable, Sendable {
    /// Mirrors `LogOutcome`, because the distinction the session reports rests on it: a stream that
    /// never opened failed, and one that opened and stopped was interrupted.
    public enum State: Equatable, Sendable {
        case connecting, following, ended
        case interrupted(LogFailure), failed(LogFailure)

        public var isTerminal: Bool {
            switch self {
            case .connecting, .following: false
            case .ended, .interrupted, .failed: true
            }
        }
    }

    public let id: UUID
    public let target: LogTarget
    public internal(set) var state: State

    public init(id: UUID = UUID(), target: LogTarget, state: State = .connecting) {
        self.id = id
        self.target = target
        self.state = state
    }

    /// What a line from this stream is labelled with when a tab has more than one.
    public var label: String { target.pod }
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
    case noPods
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
        case .noPods: "This deployment has no pods to tail. Resume once it has some."
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
