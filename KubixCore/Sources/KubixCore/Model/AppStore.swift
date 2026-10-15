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
    public internal(set) var rows: [ResourceRow] = []
    public internal(set) var columns: [KubernetesTable.ColumnDefinition]?
    public internal(set) var connection: ListConnection = .idle
    /// Which kind the one list slot above currently describes. Exactly one watch runs, so the rows,
    /// columns and connection belong to this kind and to no other.
    public internal(set) var listKind: ResourceKind = .pods
    public internal(set) var listFilter = ""
    public internal(set) var listWide = false
    public internal(set) var listSort: ResourceTablePresentation.Sort?
    public internal(set) var selectedRowUIDs: Set<String> = []
    public var selectedRowUID: String? { selectedRowUIDs.count == 1 ? selectedRowUIDs.first : nil }
    public internal(set) var execSessions: [ExecSession] = []
    public internal(set) var logSessions: [LogSession] = []
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
    /// Which button is waiting for the details its menu will list, so only that one shows progress.
    public internal(set) var pendingContainerPurpose: ContainerPickerPresentation.Purpose?
    public internal(set) var podShellDiagnostic: String?
    public internal(set) var containerPicker: ContainerPickerPresentation?
    public internal(set) var podDeletion: PodDeletionPresentation?
    public internal(set) var podDeleteDiagnostic: String?
    /// Open order across both kinds, which is the order the deck's one strip shows them in.
    public internal(set) var sessionOrder: [SessionSelection] = []
    /// The one session the deck shows. A shell and a log tail share one strip, so a pair of
    /// independent selections could represent two visible sessions at once, which cannot happen.
    public internal(set) var selectedSession: SessionSelection?
    public internal(set) var surfaceRevision = 0

    /// The exec/log deck's share of the detail pane. Half by default: a shell is the reason the deck
    /// exists, and the old automatic split opened it barely tall enough to read two lines.
    public internal(set) var deckFraction = AppStore.deckFractionDefault
    public internal(set) var deckCollapsed = false

    /// Still-open sessions in the order they were opened. A closed shell stays in `execSessions`
    /// until its surface is freed, so membership is the wrong question to ask of either array.
    public var openSessions: [SessionSelection] {
        sessionOrder.filter { selection in
            switch selection {
            case .shell(let id): execSessions.contains { $0.id == id && !$0.isClosed }
            case .logs(let id): logSessions.contains { $0.id == id && !$0.isClosed }
            }
        }
    }

    public var lastOpenSession: SessionSelection? { openSessions.last }

    public static let deckFractionDefault: Double = 0.5
    public static let deckFractionMinimum: Double = 0.15
    public static let deckFractionMaximum: Double = 0.85

    /// Usage by pod name for the watched namespace; nil until the first sample for this scope.
    public internal(set) var podMetrics: [String: PodUsage]?

    public var listTable: ResourceTablePresentation {
        // The usage columns belong to the cluster, not the sample: they appear once the cluster has
        // served metrics and stay while the next namespace's first sample is on its way.
        let available = listKind.supportsUsageColumns
            && clusters.first { $0.context == selectedContext }?.metrics == .available
        return ResourceTablePresentation(
            kind: listKind, rows: rows, columns: columns, connection: connection, filter: listFilter,
            wide: listWide, sort: listSort, selectedUIDs: selectedRowUIDs,
            metrics: available ? (podMetrics ?? [:]) : nil
        )
    }

    /// Only the focused cluster's sessions. Every cluster's credential work lands in one list, so an
    /// unscoped view shows another cluster's finished sign-in beside this one's and reads as a
    /// duplicate — the rows are identical apart from an identity the user cannot see.
    public var focusedAuthenticationSessions: [AuthSession] {
        guard let context = selectedContext else { return [] }
        return visibleAuthenticationSessions.filter { $0.credentialIdentity.belongs(to: context, settings: authSettings) }
    }

    /// The focused cluster's sessions that want something from the user: a browser approval to
    /// complete, or a failure with its Retry. A plugin quietly refreshing an expired token asks for
    /// nothing — it finishes in a moment and the action waiting on it says so itself — and a finished
    /// sign-in only reports that something worked, which the list it was for already shows.
    public var attentionAuthenticationSessions: [AuthSession] {
        focusedAuthenticationSessions.filter { $0.state == .waitingForBrowser || $0.state == .failed }
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
