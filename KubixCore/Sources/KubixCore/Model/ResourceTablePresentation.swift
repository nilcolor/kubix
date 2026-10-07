import Foundation

/// The server's printed columns, plus what a list needs that the server does not print. Server cell
/// positions still identify every server column, so a schema change never re-keys a sort. Two
/// columns are the app's own: the Age the server prints is replaced by one computed from the row's
/// creation time, because a printed age freezes until the row next changes; and CPU and memory come
/// from the metrics API, which no Table carries and which only pods have at all.
public struct ResourceTablePresentation: Equatable, Sendable {
    public struct Sort: Equatable, Sendable {
        public let column: Int
        public let ascending: Bool
        public init(column: Int, ascending: Bool = true) {
            self.column = column
            self.ascending = ascending
        }
    }

    public struct Column: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// Printed by the server; `id` is its cell position.
            case server
            /// The server's Age column, displayed from `Row.created` and sorted by it.
            case age
            case cpu
            case memory
        }

        /// A server cell position, or a negative id for a column the app computes.
        public let id: Int
        public let definition: KubernetesTable.ColumnDefinition
        public let kind: Kind

        /// Live columns change on their own, so they are not search keys: a filter that matched
        /// `5m` a minute ago would silently stop matching as the age ticked past it.
        public var isSearchable: Bool { kind == .server }

        public static let cpu = Column(
            id: -1, definition: .init(name: "CPU", type: "string", description: "Usage in millicores, as kubectl top reports it"),
            kind: .cpu
        )
        public static let memory = Column(
            id: -2, definition: .init(name: "Memory", type: "string", description: "Usage in mebibytes, as kubectl top reports it"),
            kind: .memory
        )
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let cells: [String]
        /// The pod's creation time, from which the Age cell is drawn at the moment it is shown.
        public let created: Date?
    }

    public enum State: Equatable, Sendable {
        case idle, connecting, listed, failed, empty, filteredEmpty, live
    }

    public let kind: ResourceKind
    public let columns: [Column]
    public let rows: [Row]
    public let sort: Sort?
    public let selectedUID: String?
    public let state: State
    public let message: String
    public let total: Int

    public init(
        kind: ResourceKind = .pods,
        rows source: [ResourceRow], columns schema: [KubernetesTable.ColumnDefinition]?,
        connection: ListConnection, filter: String = "", wide: Bool = false,
        sort: Sort? = nil, selectedUID: String? = nil, metrics: [String: PodUsage]? = nil
    ) {
        self.kind = kind
        // Usage is per pod and has no deployment equivalent, so a caller that offers samples for a
        // kind that cannot have them is ignored rather than trusted.
        let metrics = kind.supportsUsageColumns ? metrics : nil
        var columns = (schema ?? []).enumerated().compactMap { index, definition -> Column? in
            guard wide || !definition.isWideOnly else { return nil }
            let age = definition.name.caseInsensitiveCompare("Age") == .orderedSame
            return Column(id: index, definition: definition, kind: age ? .age : .server)
        }
        // Usage sits where every other client puts it, just before Age.
        if metrics != nil {
            let position = columns.firstIndex { $0.kind == .age } ?? columns.endIndex
            columns.insert(contentsOf: [.cpu, .memory], at: position)
        }
        self.columns = columns
        // A hidden column must not invisibly control either sorting or filtering.
        self.sort = sort.flatMap { candidate in columns.contains { $0.id == candidate.column } ? candidate : nil }
        let valid = (source.isEmpty && connection != .live) || (schema != nil && source.allSatisfy { $0.cells.count == schema?.count })
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        var displayed = valid ? source.filter { row in
            query.isEmpty || columns.contains {
                $0.isSearchable && row.cells[$0.id].displayText
                    .range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: Self.locale) != nil
            }
        } : []
        if let sort = self.sort, let column = columns.first(where: { $0.id == sort.column }) {
            displayed = displayed.enumerated().sorted { lhs, rhs in
                let left = Self.key(lhs.element, column, metrics: metrics)
                let right = Self.key(rhs.element, column, metrics: metrics)
                if left == .null || right == .null {
                    if left != right { return right == .null }
                }
                let comparison = Self.compare(left, right)
                if comparison == .orderedSame { return lhs.offset < rhs.offset }
                return comparison == (sort.ascending ? .orderedAscending : .orderedDescending)
            }.map(\.element)
        }
        let rows = displayed.map { row in
            Row(
                id: row.id, cells: columns.map { Self.text(row, $0, metrics: metrics) },
                created: row.metadata.creationTimestamp
            )
        }
        self.rows = rows
        self.selectedUID = selectedUID.flatMap { uid in rows.contains { $0.id == uid } ? uid : nil }
        total = source.count
        (state, message) = Self.status(
            connection, kind: kind, valid: valid, total: source.count, visible: rows.count
        )
    }

    /// The short form for a window subtitle: a count and its state, without the sentence the pane
    /// uses when something needs acting on.
    public var subtitle: String {
        switch state {
        case .idle: "Not connected"
        case .connecting: rows.isEmpty ? "Connecting…" : "Reconnecting…"
        case .listed: "Listed"
        case .failed: "Failed"
        case .empty: "No \(kind.noun.many)"
        case .filteredEmpty: "No matches"
        case .live: rows.count == total
            ? "\(total) \(noun(total))"
            : "\(rows.count) of \(total) \(noun(total))"
        }
    }

    private func noun(_ count: Int) -> String { count == 1 ? kind.noun.one : kind.noun.many }

    private static func noun(_ count: Int, _ kind: ResourceKind) -> String {
        count == 1 ? kind.noun.one : kind.noun.many
    }

    private static let locale = Locale(identifier: "en_US_POSIX")

    /// What a column sorts by. Age sorts by creation time, which never changes, so the order stays
    /// correct without a clock; usage sorts by the exact value rather than the rounded display.
    private static func key(_ row: ResourceRow, _ column: Column, metrics: [String: PodUsage]?) -> TableCell {
        switch column.kind {
        case .server: return row.cells[column.id]
        case .age:
            guard let created = row.metadata.creationTimestamp else { return row.cells[column.id] }
            // Youngest first when ascending, which is what a smaller age means.
            return .number(Decimal(-created.timeIntervalSince1970))
        case .cpu: return usage(row, metrics).map { .number($0.cpuNanocores) } ?? .null
        case .memory: return usage(row, metrics).map { .number($0.memoryBytes) } ?? .null
        }
    }

    private static func text(_ row: ResourceRow, _ column: Column, metrics: [String: PodUsage]?) -> String {
        switch column.kind {
        // The Age text is drawn from `Row.created` when shown; this is only the fallback for a row
        // the server sent without a creation time.
        case .server, .age: return row.cells[column.id].displayText
        case .cpu: return usage(row, metrics).map { UsageFormat.cpu($0.cpuNanocores) } ?? absent
        case .memory: return usage(row, metrics).map { UsageFormat.memory($0.memoryBytes) } ?? absent
        }
    }

    /// A pod with no numbers is not a pod using nothing: Pending, completed and newly started pods
    /// have no sample yet, and a third of a busy namespace can be in that state.
    public static let absent = "—"

    /// The metrics API names a pod but carries no UID, so a pod recreated under the same name — a
    /// StatefulSet replica — could briefly inherit its predecessor's numbers. A sample whose window
    /// began before this pod existed cannot describe it. A second of slack covers the timestamps'
    /// whole-second precision.
    static func usage(_ row: ResourceRow, _ metrics: [String: PodUsage]?) -> PodUsage? {
        guard let name = row.metadata.name, let sample = metrics?[name] else { return nil }
        if let created = row.metadata.creationTimestamp, sample.windowStart < created.addingTimeInterval(-1) { return nil }
        return sample
    }

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

    private static func status(
        _ connection: ListConnection, kind: ResourceKind, valid: Bool, total: Int, visible: Int
    ) -> (State, String) {
        let many = kind.noun.many
        let counted = noun(total, kind)
        guard valid else {
            return (.failed, "\(kind.title) cells do not match the server column definitions. Refresh to retry.")
        }
        switch connection {
        case .idle: return (.idle, "Choose a context and namespace, then load \(many).")
        case .connecting:
            return (.connecting, total == 0
                ? "Connecting — waiting for a complete \(kind.noun.one) list and watch."
                : "Reconnecting — \(total) last-known \(counted); updates are not live.")
        case .listed:
            let shown = total == 0 ? "no \(many) in this namespace" : "\(visible) of \(total) \(counted)"
            return (.listed, "Listed — \(shown). Waiting for live updates to start.")
        case .failed(let error):
            let prefix = error.httpCode == 403 ? "Forbidden: \(many). Check access to this namespace. " : ""
            let stale = total == 0 ? "" : " Showing \(total) last-known \(counted); updates are not live."
            return (.failed, prefix + error.description + stale)
        case .live:
            if total == 0 { return (.empty, "Live — no \(many) in this namespace.") }
            if visible == 0 {
                return (.filteredEmpty, "Live — no matches in \(total) \(counted). Clear the filter to see them.")
            }
            return (.live, "Live — \(visible) of \(total) \(counted).")
        }
    }
}
