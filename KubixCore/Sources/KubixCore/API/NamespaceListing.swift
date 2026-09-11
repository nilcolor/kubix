import Foundation

/// Optional enhancement, never a requirement: many clusters deny `list namespaces` to human users, and
/// typing a known namespace has to keep working without it.
public protocol NamespaceListing: Sendable {
    func namespaces(context: ResolvedContext) async throws -> [String]
}

public enum NamespaceListFailure: String, Error, Equatable, Sendable {
    case malformed
    /// A truncated list is not a list: the caller replaces local history with a complete one, so a
    /// partial result would silently drop namespaces the user has typed before.
    case tooManyPages
    case tooManyBytes
}
