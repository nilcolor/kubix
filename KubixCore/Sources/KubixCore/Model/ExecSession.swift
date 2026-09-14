import Foundation

/// A resolved snapshot, never a lookup through the current UI selection.
public struct ExecTarget: Equatable, Sendable {
    public let context: ResolvedContext
    public let namespace: String
    public let pod: String
    public let container: String

    public init(context: ResolvedContext, namespace: String, pod: String, container: String) throws {
        _ = try ExecRequest(namespace: namespace, pod: pod, container: container, command: ["sh"])
        self.context = context
        self.namespace = namespace
        self.pod = pod
        self.container = container
    }
}

public enum ExecFailure: Error, Equatable, Sendable {
    case api(APIError)
    case remote(KubernetesStatus)
    case protocolViolation
    case bridge
    case childTerminated
    case surface
    case authentication(String)

    public var diagnostic: String {
        switch self {
        case .api(let error): error.description
        case .remote(let status):
            "\(status.reason ?? "Exec failure"): \(status.message ?? "The server could not execute the command.")"
        case .protocolViolation: "The exec peer sent an invalid protocol message."
        case .bridge: "The local terminal bridge failed or its handshake timed out."
        case .childTerminated: "The local terminal closed before a remote command outcome was received."
        case .surface: "The terminal surface could not be created."
        case .authentication(let diagnostic): diagnostic
        }
    }
}

public enum ExecSessionResult: Equatable, Sendable {
    case exited(code: Int)
    case failed(ExecFailure)
    case cancelled
}

public struct ExecSession: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case authenticating, connecting, running
        case finished(ExecSessionResult)

        public var isTerminal: Bool {
            if case .finished = self { return true }
            return false
        }
    }

    public let id: UUID
    public let target: ExecTarget
    /// The pod's containers as validated when this session opened, for the container switch alone.
    /// Never a later lookup: the session's own target stays the immutable snapshot it always was.
    public let containers: [PodDetails.Container]
    public internal(set) var state: State = .authenticating
    public internal(set) var isClosed = false

    public init(id: UUID = UUID(), target: ExecTarget, containers: [PodDetails.Container] = []) {
        self.id = id
        self.target = target
        self.containers = containers
    }
}
