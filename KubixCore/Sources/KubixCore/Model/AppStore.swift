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

    /// The exec/log deck's share of the detail pane. Half by default: a shell is the reason the deck
    /// exists, and the old automatic split opened it barely tall enough to read two lines.
    public internal(set) var deckFraction = AppStore.deckFractionDefault

    public static let deckFractionDefault: Double = 0.5
    public static let deckFractionMinimum: Double = 0.15
    public static let deckFractionMaximum: Double = 0.85

    public var podTable: PodTablePresentation {
        PodTablePresentation(
            rows: rows, columns: columns, connection: connection, filter: podFilter,
            wide: podWide, sort: podSort, selectedUID: selectedPodUID
        )
    }

    /// Only the focused cluster's sessions. Every cluster's credential work lands in one list, so an
    /// unscoped view shows another cluster's finished sign-in beside this one's and reads as a
    /// duplicate — the rows are identical apart from an identity the user cannot see.
    public var focusedAuthenticationSessions: [AuthSession] {
        guard let context = selectedContext else { return [] }
        return visibleAuthenticationSessions.filter { $0.credentialIdentity.belongs(to: context, settings: authSettings) }
    }

    /// The focused cluster's sessions that still want something: credentials being acquired, a browser
    /// approval to complete, or a failure with its Retry. A finished sign-in says only that the thing
    /// the user just did worked, which the list it was for already shows.
    public var attentionAuthenticationSessions: [AuthSession] {
        focusedAuthenticationSessions.filter { $0.state != .succeeded && $0.state != .cancelled }
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
