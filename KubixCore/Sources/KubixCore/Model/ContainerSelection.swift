import Foundation

/// Logs is a future selection policy only; it does not start an unimplemented log service.
public struct ContainerSelection: Equatable, Sendable {
    public let shell: [PodDetails.Container]
    public let logs: [PodDetails.Container]
    public let defaultShell: String?
    public var unavailableExplanation: String? {
        shell.isEmpty ? "No running regular container is available for a shell yet. Init and ephemeral containers are not shell targets." : nil
    }

    public init(details: PodDetails) {
        shell = details.containers.filter { $0.kind == .regular && $0.state == .running }
        logs = details.containers
        defaultShell = shell.first { $0.name == details.defaultContainer }?.name ?? shell.first?.name
    }
}

public struct ContainerPickerPresentation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let pod: String
    public let containers: [String]
    public let defaultContainer: String
}

/// An immutable row revision and generation, never a later name lookup through the current context.
struct PodShellSelection: Equatable, Sendable {
    let id: UUID
    let generation: UUID
    let podGeneration: UUID
    let configurationRevision: Int
    let context: ResolvedContext
    let namespace: String
    let row: PodRow
}
