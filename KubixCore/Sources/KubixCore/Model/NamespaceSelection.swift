import Foundation

/// Local, per-context history. Never discovers namespaces from the cluster.
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

    public mutating func remember(_ namespace: String, for context: ResolvedContext) throws {
        guard Self.isValid(namespace) else { throw APIError.invalidRequest }
        if entered[context.name]?.contains(namespace) != true {
            entered[context.name, default: []].append(namespace)
        }
    }
}
