import Foundation

@MainActor
public protocol BrowserOpening: Sendable {
    /// Return false when the system could not open the URL. Never log authorization URLs.
    func open(_ url: URL) async -> Bool
}
