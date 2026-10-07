import Foundation

public struct ContainerSelection: Equatable, Sendable {
    public let shell: [PodDetails.Container]
    public let logs: [PodDetails.Container]
    public let defaultShell: String?
    public let defaultLog: PodDetails.Container?
    /// What the pod nominates, whether or not it is a candidate for either purpose.
    public let annotated: String?
    public var unavailableExplanation: String? {
        shell.isEmpty ? "No running regular container is available for a shell yet. Init and ephemeral containers are not shell targets." : nil
    }

    public init(details: PodDetails) {
        annotated = details.defaultContainer
        shell = details.containers.filter { $0.kind == .regular && $0.state == .running }
        logs = details.containers
        defaultShell = shell.first { $0.name == details.defaultContainer }?.name ?? shell.first?.name
        defaultLog = logs.first { $0.kind == .regular && $0.name == details.defaultContainer }
            ?? logs.first { $0.kind == .regular } ?? logs.first
    }
}

/// One menu's worth of containers: what each one is for, and which one the pod itself nominates.
public struct ContainerPickerPresentation: Identifiable, Equatable, Sendable {
    public enum Purpose: Equatable, Sendable {
        case shell, logs

        public var title: String { self == .shell ? "Open shell in" : "Open logs in" }
        public var hint: String {
            self == .shell ? "Choosing a container opens the terminal immediately."
                : "Choosing a container opens the log tail immediately."
        }
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public let name: String
        public let role: String
        public let state: String
        public var id: String { name }

        public init(_ container: PodDetails.Container, annotated: Bool) {
            name = container.name
            role = Self.role(container, isDefault: annotated)
            state = container.state.rawValue.capitalized
        }

        private static func role(_ container: PodDetails.Container, isDefault: Bool) -> String {
            if isDefault { return "Default container" }
            if container.isSidecar { return "Sidecar" }
            switch container.kind {
            case .regular: return "Container"
            case .initContainer: return "Init container"
            case .ephemeral: return "Ephemeral container"
            }
        }
    }

    public let id: UUID
    public let purpose: Purpose
    public let pod: String
    public let items: [Item]
    public let defaultContainer: String
    public var containers: [String] { items.map(\.name) }

    /// `annotated` is the pod's `kubectl.kubernetes.io/default-container`, which names a container
    /// that may not be a candidate at all; `defaultContainer` is the candidate this menu preselects.
    public init(
        id: UUID, purpose: Purpose, pod: String, containers: [PodDetails.Container],
        defaultContainer: String, annotated: String?
    ) {
        self.id = id
        self.purpose = purpose
        self.pod = pod
        items = containers.map { Item($0, annotated: $0.name == annotated) }
        self.defaultContainer = defaultContainer
    }
}

/// An immutable row revision and generation, never a later name lookup through the current context.
/// The purpose says which generation it belongs to: a pending shell and a pending log tail are
/// separate requests for separate tabs, so starting one must not discard the other.
struct RowSelection: Equatable, Sendable {
    let id: UUID
    let purpose: ContainerPickerPresentation.Purpose
    let generation: UUID
    let listGeneration: UUID
    let configurationRevision: Int
    let context: ResolvedContext
    let namespace: String
    let row: ResourceRow
}
