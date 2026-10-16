import Foundation

/// Local, per-context history of namespaces the user typed. Discovery from the cluster is separate and
/// optional — see `NamespaceDiscovery` — because listing namespaces is a permission many clusters deny,
/// and typing a known name must keep working without it.
public struct NamespaceSelection: Sendable {
    private var entered: [String: [String]] = [:]

    public init() {}

    public static func isValid(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...63).contains(bytes.count), let first = bytes.first, let last = bytes.last else { return false }
        func alphanumeric(_ byte: UInt8) -> Bool { (97...122).contains(byte) || (48...57).contains(byte) }
        return alphanumeric(first) && alphanumeric(last) && bytes.allSatisfy { alphanumeric($0) || $0 == 45 }
    }

    public static func defaultNamespace(for context: ResolvedContext?) -> String {
        guard let namespace = context?.namespace, !namespace.isEmpty else { return "default" }
        return namespace
    }

    public func suggestions(for context: ResolvedContext?) -> [String] {
        let configured = Self.defaultNamespace(for: context)
        let history = context.flatMap { entered[$0.name] } ?? []
        return (Self.isValid(configured) ? [configured] : []) + history.filter { $0 != configured }
    }

    /// A cluster's own list is complete, so it replaces local history rather than adding to it: a
    /// namespace that has since been deleted should stop being offered. History is kept regardless, so
    /// losing the permission later does not lose the names the user typed.
    public func options(for context: ResolvedContext?, discovery: NamespaceDiscovery) -> [String] {
        guard case .listed(let names) = discovery else { return suggestions(for: context) }
        return Set(names.filter(Self.isValid)).sorted()
    }

    /// Case-insensitive substring match, with names that start with the query ranked first so typing
    /// the head of a name puts it on top even when it also appears inside others.
    public static func matching(_ names: [String], filter: String) -> [String] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return names }
        let hits = names.filter { $0.lowercased().contains(query) }
        let leading = hits.filter { $0.lowercased().hasPrefix(query) }
        return leading + hits.filter { !$0.lowercased().hasPrefix(query) }
    }

    public mutating func remember(_ namespace: String, for context: ResolvedContext) throws {
        guard Self.isValid(namespace) else { throw APIError.invalidRequest }
        if entered[context.name]?.contains(namespace) != true {
            entered[context.name, default: []].append(namespace)
        }
    }
}
