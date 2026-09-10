import Foundation
import KubixCore

public protocol AuthSettingsStoring: Sendable {
    func load() async throws -> AuthSettings
    func save(_ settings: AuthSettings) async throws
}

/// The app supplies its settings URL. This adapter never chooses or modifies a user AWS/kube file.
public actor FileAuthSettingsStore: AuthSettingsStoring {
    private let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> AuthSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return AuthSettings() }
        do {
            let settings = try JSONDecoder().decode(AuthSettings.self, from: Data(contentsOf: url))
            try settings.validate()
            return settings
        } catch { throw AuthenticationError.settingsUnavailable }
    }

    public func save(_ settings: AuthSettings) throws {
        try settings.validate()
        do { try JSONEncoder().encode(settings).write(to: url, options: .atomic) } catch {
            throw AuthenticationError.settingsUnavailable
        }
    }
}

public actor MemoryAuthSettingsStore: AuthSettingsStoring {
    private var settings: AuthSettings
    public init(_ settings: AuthSettings = AuthSettings()) { self.settings = settings }
    public func load() -> AuthSettings { settings }
    public func save(_ settings: AuthSettings) throws {
        try settings.validate()
        self.settings = settings
    }
}
