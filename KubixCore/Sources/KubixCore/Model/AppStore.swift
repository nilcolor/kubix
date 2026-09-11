import Foundation
import Observation

/// In-memory only. In particular, auth instructions and resolved credentials are not Codable.
@Observable @MainActor
public final class AppStore {
    public internal(set) var contexts: [ResolvedContext]
    public internal(set) var clusters: [ClusterStatus]
    public internal(set) var sidebarSelection: SidebarSelection?
    public internal(set) var selectedContext: ResolvedContext?
    public internal(set) var namespaces: [String]
    public internal(set) var selectedNamespace: String
    public internal(set) var namespaceDraft: String
    public internal(set) var namespaceDiagnostic: String?
    public internal(set) var rows: [PodRow] = []
    public internal(set) var columns: [KubernetesTable.ColumnDefinition]?
    public internal(set) var connection: PodConnection = .idle
    public internal(set) var podFilter = ""
    public internal(set) var podWide = false
    public internal(set) var podSort: PodTablePresentation.Sort?
    public internal(set) var selectedPodUID: String?
    public internal(set) var execSessions: [ExecSession] = []
    public internal(set) var logSessions: [LogSession] = []
    public internal(set) var selectedLogSessionID: UUID?
    public internal(set) var podLogDiagnostic: String?
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
    public internal(set) var isLoadingPodDetails = false
    public internal(set) var podShellDiagnostic: String?
    public internal(set) var containerPicker: ContainerPickerPresentation?
    public internal(set) var selectedExecSessionID: UUID?
    public internal(set) var surfaceRevision = 0

    public var podTable: PodTablePresentation {
        PodTablePresentation(
            rows: rows, columns: columns, connection: connection, filter: podFilter,
            wide: podWide, sort: podSort, selectedUID: selectedPodUID
        )
    }

    public var visibleAuthenticationSessions: [AuthSession] {
        var completed = Set<CredentialIdentity>()
        let newestFirst = authenticationSessionOrder.reversed().compactMap { authenticationSessions[$0] }.filter {
            !$0.state.isTerminal || completed.insert($0.credentialIdentity).inserted
        }
        return Array(newestFirst.reversed())
    }

    public init(contexts: [ResolvedContext] = [], authSettings: AuthSettings = AuthSettings()) {
        self.contexts = contexts
        clusters = contexts.map { ClusterStatus(context: $0) }
        sidebarSelection = contexts.first.map { .cluster($0.name) }
        selectedContext = contexts.first
        selectedNamespace = NamespaceSelection.defaultNamespace(for: contexts.first)
        namespaceDraft = NamespaceSelection.defaultNamespace(for: contexts.first)
        // A fresh store has asked no cluster anything, so the options are local history alone.
        namespaces = NamespaceSelection().options(for: contexts.first, discovery: .unknown)
        self.authSettings = authSettings
        settingsDraft = AuthSettingsDraft(settings: authSettings, context: contexts.first)
    }
}
