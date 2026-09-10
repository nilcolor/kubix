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
    var authenticationSessionOrder: [UUID] = []
    public internal(set) var authSettings: AuthSettings
    public internal(set) var authenticationDiagnostic: String?
    public internal(set) var configurationDiagnostics: [String] = []
    public internal(set) var isLoadingConfiguration = false
    public internal(set) var hasLoadedConfiguration = false
    public internal(set) var pluginPresentation = AuthPluginPresentation()
    public internal(set) var settingsDraft: AuthSettingsDraft
    public internal(set) var settingsDiagnostic: String?
    public internal(set) var showingSettings = false
    public internal(set) var useDeviceCode = false
    public internal(set) var podName = ""
    public internal(set) var containerName = ""
    public internal(set) var connectDiagnostic: String?
    public internal(set) var selectedExecSessionID: UUID?
    public internal(set) var surfaceRevision = 0

    public var visibleAuthenticationSessions: [AuthSession] {
        var completed = Set<CredentialIdentity>()
        let newestFirst = authenticationSessionOrder.reversed().compactMap { authenticationSessions[$0] }.filter {
            !$0.state.isTerminal || completed.insert($0.credentialIdentity).inserted
        }
        return Array(newestFirst.reversed())
    }

    public init(contexts: [ResolvedContext] = [], authSettings: AuthSettings = AuthSettings()) {
        self.contexts = contexts
        selectedContext = contexts.first
        selectedNamespace = contexts.first?.namespace ?? "default"
        namespaces = [contexts.first?.namespace ?? "default"]
        self.authSettings = authSettings
        settingsDraft = AuthSettingsDraft(settings: authSettings, context: contexts.first)
    }
}
