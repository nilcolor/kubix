import Foundation

public struct PodRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let metadata: KubernetesObjectMetadata
    public let cells: [TableCell]

    public init(row: KubernetesTable.Row) throws {
        guard let metadata = row.object?.metadata, let uid = metadata.uid,
              !uid.isEmpty, uid.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "A pod Table row requires a nonempty metadata.uid."))
        }
        // Kubernetes UIDs are opaque strings, not necessarily UUIDs, and must never come from a display cell.
        id = uid
        self.metadata = metadata
        cells = row.cells
    }

    public func displayCells(using columns: [KubernetesTable.ColumnDefinition], wide: Bool = false) throws -> [String] {
        guard columns.count == cells.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Table cells do not match the column schema."))
        }
        return zip(columns, cells).compactMap { column, cell in
            wide || !column.isWideOnly ? cell.displayText : nil
        }
    }
}
