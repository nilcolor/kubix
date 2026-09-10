import Foundation

public enum PodConnection: Equatable, Sendable {
    case idle, connecting, live, failed(APIError)
}

public struct PodWatchUpdate: Equatable, Sendable {
    public let rows: [PodRow]
    public let columns: [KubernetesTable.ColumnDefinition]?
    public let connection: PodConnection

    public init(rows: [PodRow], columns: [KubernetesTable.ColumnDefinition]?, connection: PodConnection) {
        self.rows = rows
        self.columns = columns
        self.connection = connection
    }
}

/// A run owns all pagination, renewal and network work until cancellation or terminal failure.
public protocol PodWatching: Sendable {
    func run(
        context: ResolvedContext, namespace: String,
        update: @escaping @MainActor @Sendable (PodWatchUpdate) -> Void
    ) async
}

public enum PodSnapshotFailure: String, Error, Equatable, Sendable {
    case malformedTable, missingResourceVersion, inconsistentResourceVersion, missingSchema
    case inconsistentSchema, invalidRow, duplicateUID, cursorCycle, cursorTooLong, pageLimit, rowLimit, byteLimit
}
