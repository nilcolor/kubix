import Foundation
import Observation

/// In-memory only. In particular, auth instructions and resolved credentials are not Codable.
@Observable @MainActor
public final class AppStore {
    public internal(set) var contexts: [ResolvedContext]
    public internal(set) var selectedContext: ResolvedContext?
    public internal(set) var namespaces: [String]
    public internal(set) var selectedNamespace: String
    public internal(set) var execSessions: [ExecSession] = []
    public internal(set) var authenticationSessions: [UUID: AuthSession] = [:]
    public internal(set) var authSettings: AuthSettings
    public internal(set) var authenticationDiagnostic: String?

    public init(contexts: [ResolvedContext] = [], authSettings: AuthSettings = AuthSettings()) {
        self.contexts = contexts
        selectedContext = contexts.first
        selectedNamespace = contexts.first?.namespace ?? "default"
        namespaces = [contexts.first?.namespace ?? "default"]
        self.authSettings = authSettings
    }
}
