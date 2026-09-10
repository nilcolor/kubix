import Foundation
import KubixCore

/// Bounds both pagination loops and retained decoded data. No partial snapshot escapes this owner.
struct PodSnapshot {
    static let maximumPages = 1_000
    static let maximumRows = 100_000
    static let maximumBytes = 128 * 1_024 * 1_024
    static let maximumCursorBytes = 16_384
    private let rowBudget: Int
    private let byteBudget: Int
    private(set) var rows: [PodRow] = []
    private(set) var columns: [KubernetesTable.ColumnDefinition]?
    private(set) var resourceVersion: String?
    private(set) var cursor = ""
    private var identifiers = Set<String>()
    private var cursors = Set<String>()
    private var pages = 0
    private var bytes = 0

    init(rowBudget: Int = Self.maximumRows, byteBudget: Int = Self.maximumBytes) {
        self.rowBudget = rowBudget
        self.byteBudget = byteBudget
    }

    mutating func append(_ data: Data, namespace: String) throws {
        guard pages < Self.maximumPages else { throw APIError.podSnapshot(.pageLimit) }
        guard data.count <= byteBudget - bytes else { throw APIError.podSnapshot(.byteLimit) }
        bytes += data.count
        pages += 1
        let table: KubernetesTable
        do { table = try JSONDecoder().decode(KubernetesTable.self, from: data) } catch {
            throw APIError.podSnapshot(.malformedTable)
        }
        try installMetadata(table)
        try appendRows(table, namespace: namespace)
        cursor = table.metadata?.continuation ?? ""
        guard cursor.utf8.count <= Self.maximumCursorBytes else { throw APIError.podSnapshot(.cursorTooLong) }
        if !cursor.isEmpty {
            guard cursors.insert(cursor).inserted else { throw APIError.podSnapshot(.cursorCycle) }
            guard pages < Self.maximumPages else { throw APIError.podSnapshot(.pageLimit) }
        }
    }

    private mutating func installMetadata(_ table: KubernetesTable) throws {
        guard let version = table.metadata?.resourceVersion, !version.isEmpty else {
            throw APIError.podSnapshot(.missingResourceVersion)
        }
        if let resourceVersion, resourceVersion != version { throw APIError.podSnapshot(.inconsistentResourceVersion) }
        resourceVersion = version
        if let schema = table.columnDefinitions {
            if let columns, columns != schema { throw APIError.podSnapshot(.inconsistentSchema) }
            columns = schema
        }
        guard columns != nil else { throw APIError.podSnapshot(.missingSchema) }
    }

    private mutating func appendRows(_ table: KubernetesTable, namespace: String) throws {
        guard table.rows.count <= rowBudget - rows.count else { throw APIError.podSnapshot(.rowLimit) }
        for row in table.rows {
            let pod: PodRow
            do { pod = try PodRow(row: row) } catch { throw APIError.podSnapshot(.invalidRow) }
            guard pod.cells.count == columns?.count, pod.metadata.namespace == namespace,
                  pod.metadata.name?.isEmpty == false else { throw APIError.podSnapshot(.invalidRow) }
            guard identifiers.insert(pod.id).inserted else { throw APIError.podSnapshot(.duplicateUID) }
            rows.append(pod)
        }
    }
}
