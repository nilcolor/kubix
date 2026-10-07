import Foundation

/// An equality-based label selector, rendered for the `labelSelector` query parameter.
///
/// Only `matchLabels` is rendered. A set-based selector (`matchExpressions`) is refused upstream in
/// `DeploymentDetails`, because serializing `In`/`NotIn`/`Exists` into this grammar has a dozen
/// encoding edges where a mistake silently selects another workload's pods and looks like it worked.
///
/// Every key and value is validated against the Kubernetes label grammar before it reaches a URL.
/// That is not percent-encoding's job: `,` and `=` are the selector's own separators, so a key
/// containing one would be a different selector rather than an invalid one, whatever the encoding.
public struct LabelSelector: Equatable, Sendable {
    public let labels: [String: String]

    public init(_ labels: [String: String]) throws {
        guard !labels.isEmpty else { throw LabelSelectorFailure.empty }
        for (key, value) in labels {
            guard Self.isValidKey(key) else { throw LabelSelectorFailure.invalidKey }
            guard Self.isValidValue(value) else { throw LabelSelectorFailure.invalidValue }
        }
        self.labels = labels
    }

    /// Sorted, so the same selector always produces the same request — a dictionary's order is not
    /// stable between runs, and an unstable query string makes requests hard to compare.
    public var query: String {
        labels.keys.sorted().map { "\($0)=\(labels[$0] ?? "")" }.joined(separator: ",")
    }

    /// `name` or `prefix/name`, where the prefix is a DNS subdomain of at most 253 characters.
    static func isValidKey(_ key: String) -> Bool {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return isValidName(String(parts[0]))
        case 2:
            let prefix = String(parts[0])
            return prefix.count <= 253 && !prefix.isEmpty
                && prefix.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(isValidSubdomainLabel)
                && isValidName(String(parts[1]))
        default: return false
        }
    }

    /// Empty is a legal label value, and `key=` is how the selector says so.
    static func isValidValue(_ value: String) -> Bool { value.isEmpty || isValidName(value) }

    /// At most 63 characters, alphanumeric at both ends, with `-`, `_` and `.` allowed between.
    private static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 63,
              let first = name.unicodeScalars.first, let last = name.unicodeScalars.last,
              isAlphanumeric(first), isAlphanumeric(last) else { return false }
        return name.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "-" || $0 == "_" || $0 == "." }
    }

    private static func isValidSubdomainLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.count <= 63,
              let first = label.unicodeScalars.first, let last = label.unicodeScalars.last,
              isAlphanumeric(first), isAlphanumeric(last) else { return false }
        return label.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "-" }
    }

    /// ASCII only, deliberately: the label grammar is `[A-Za-z0-9]`, and `CharacterSet
    /// .alphanumerics` would also admit every Unicode letter and digit.
    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}

public enum LabelSelectorFailure: String, Error, Equatable, Sendable {
    case empty, invalidKey, invalidValue

    public var diagnostic: String {
        switch self {
        case .empty: "This deployment has no pod selector, so its pods cannot be identified."
        case .invalidKey, .invalidValue:
            "This deployment's pod selector uses a label Kubix cannot address safely. "
                + "Open logs on its pods from the Pods list instead."
        }
    }
}
