import Foundation

public enum ListConnection: Equatable, Sendable {
    /// `listed` is a complete snapshot whose watch has not been established yet. It is distinct from
    /// `connecting` because the rows are already correct and current: an apiserver defers a quiet
    /// watch's response until its first bookmark, about a minute on an idle namespace, and calling
    /// that "connecting" tells the user nothing has arrived while a correct list is on screen.
    case idle, connecting, listed, live, failed(APIError)
}

public struct ResourceListUpdate: Equatable, Sendable {
    /// Which kind these rows and columns describe. The store keeps one list slot, so an update that
    /// arrives after the selection moved to another kind must be identifiable as the wrong one —
    /// generations already reject it, and this makes a mismatch impossible to render rather than
    /// merely unlikely.
    public let kind: ResourceKind
    public let rows: [ResourceRow]
    public let columns: [KubernetesTable.ColumnDefinition]?
    public let connection: ListConnection

    public init(
        kind: ResourceKind, rows: [ResourceRow],
        columns: [KubernetesTable.ColumnDefinition]?, connection: ListConnection
    ) {
        self.kind = kind
        self.rows = rows
        self.columns = columns
        self.connection = connection
    }
}

/// A run owns all pagination, renewal and network work until cancellation or terminal failure.
public protocol ResourceWatching: Sendable {
    func run(
        kind: ResourceKind, context: ResolvedContext, namespace: String,
        update: @escaping @MainActor @Sendable (ResourceListUpdate) -> Void
    ) async
}

public enum SnapshotFailure: String, Error, Equatable, Sendable {
    case malformedTable, missingResourceVersion, inconsistentResourceVersion, missingSchema
    case inconsistentSchema, invalidRow, duplicateUID, cursorCycle, cursorTooLong, pageLimit, rowLimit, byteLimit
}
