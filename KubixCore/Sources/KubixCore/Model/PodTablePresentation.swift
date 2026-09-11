import Foundation

/// Server cell positions, never pod-specific column names, define the display and sort keys.
public struct PodTablePresentation: Equatable, Sendable {
    public struct Sort: Equatable, Sendable {
        public let column: Int
        public let ascending: Bool
        public init(column: Int, ascending: Bool = true) {
            self.column = column
            self.ascending = ascending
        }
    }

    public struct Column: Identifiable, Equatable, Sendable {
        public let id: Int
        public let definition: KubernetesTable.ColumnDefinition
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let cells: [String]
    }

    public enum State: Equatable, Sendable {
        case idle, connecting, listed, failed, empty, filteredEmpty, live
    }

    public let columns: [Column]
    public let rows: [Row]
    public let sort: Sort?
    public let selectedUID: String?
    public let state: State
    public let message: String

    public init(
        rows source: [PodRow], columns schema: [KubernetesTable.ColumnDefinition]?,
        connection: PodConnection, filter: String = "", wide: Bool = false,
        sort: Sort? = nil, selectedUID: String? = nil
    ) {
        let columns = (schema ?? []).enumerated().compactMap {
            wide || !$0.element.isWideOnly ? Column(id: $0.offset, definition: $0.element) : nil
        }
        self.columns = columns
        // A hidden column must not invisibly control either sorting or filtering.
        self.sort = sort.flatMap { candidate in columns.contains { $0.id == candidate.column } ? candidate : nil }
        let valid = (source.isEmpty && connection != .live) || (schema != nil && source.allSatisfy { $0.cells.count == schema?.count })
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        var displayed = valid ? source.filter { row in
            query.isEmpty || columns.contains {
                row.cells[$0.id].displayText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: Self.locale) != nil
            }
        } : []
        if let sort = self.sort {
            displayed = displayed.enumerated().sorted { lhs, rhs in
                let left = lhs.element.cells[sort.column]
                let right = rhs.element.cells[sort.column]
                if left == .null || right == .null {
                    if left != right { return right == .null }
                }
                let comparison = Self.compare(left, right)
                if comparison == .orderedSame { return lhs.offset < rhs.offset }
                return comparison == (sort.ascending ? .orderedAscending : .orderedDescending)
            }.map(\.element)
        }
        let rows = displayed.map { row in Row(id: row.id, cells: columns.map { row.cells[$0.id].displayText }) }
        self.rows = rows
        self.selectedUID = selectedUID.flatMap { uid in rows.contains { $0.id == uid } ? uid : nil }
        (state, message) = Self.status(connection, valid: valid, total: source.count, visible: rows.count)
    }

    private static let locale = Locale(identifier: "en_US_POSIX")

    private static func compare(_ left: TableCell, _ right: TableCell) -> ComparisonResult {
        // Comparing some mixed pairs as text but others numerically can form sort cycles.
        if rank(left) != rank(right) { return rank(left) < rank(right) ? .orderedAscending : .orderedDescending }
        switch (left, right) {
        case (.number(let lhs), .number(let rhs)):
            return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        case (.boolean(let lhs), .boolean(let rhs)):
            return lhs == rhs ? .orderedSame : (rhs ? .orderedAscending : .orderedDescending)
        default:
            return left.displayText.compare(right.displayText, options: [.caseInsensitive, .diacriticInsensitive, .numeric], locale: locale)
        }
    }

    private static func rank(_ cell: TableCell) -> Int {
        switch cell {
        case .number: 0
        case .boolean: 1
        case .string: 2
        case .array: 3
        case .object: 4
        case .null: 5
        }
    }

    private static func status(_ connection: PodConnection, valid: Bool, total: Int, visible: Int) -> (State, String) {
        guard valid else { return (.failed, "Pod cells do not match the server column definitions. Refresh to retry.") }
        switch connection {
        case .idle: return (.idle, "Choose a context and namespace, then load pods.")
        case .connecting:
            return (.connecting, total == 0
                ? "Connecting — waiting for a complete pod list and watch."
                : "Reconnecting — \(total) last-known pods; updates are not live.")
        case .listed:
            let counted = total == 0 ? "no pods in this namespace" : "\(visible) of \(total) pods"
            return (.listed, "Listed — \(counted). Waiting for live updates to start.")
        case .failed(let error):
            let prefix = error.httpCode == 403 ? "Forbidden: pods. Check access to this namespace. " : ""
            let stale = total == 0 ? "" : " Showing \(total) last-known pods; updates are not live."
            return (.failed, prefix + error.description + stale)
        case .live:
            if total == 0 { return (.empty, "Live — no pods in this namespace.") }
            if visible == 0 { return (.filteredEmpty, "Live — no matches in \(total) pods. Clear the filter to see them.") }
            return (.live, "Live — \(visible) of \(total) pods.")
        }
    }
}
