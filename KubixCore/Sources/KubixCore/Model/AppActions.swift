import Dispatch
import Foundation

/// One cluster's namespace listing state: the attempt that owns it, the snapshot it was started for,
/// and when it last succeeded, for the refresh throttle.
struct NamespaceFetch {
    var generation: UUID
    var context: ResolvedContext
    var task: Task<Void, Never>?
    var succeededAt: TimeInterval?
}

@MainActor
public final class AppActions {
    public let store: AppStore
    let exec: any ExecSessionControlling
    let authentication: any AuthenticationControlling
    let surfaces: any TerminalSurfaceCreating
    let browser: (any BrowserOpening)?
    let configurations: (any AppConfigurationLoading)?
    var presentationRevision = 0
    var configurationRevision = 0
    var presentationTask: Task<Void, Never>?
    var tasks: [UUID: Task<Void, Never>] = [:]
    private var closingTasks: [UUID: Task<Void, Never>] = [:]
    var attempts: [UUID: UUID] = [:]
    var lifetimes: [UUID: TerminalSurfaceLifetime] = [:]
    private var progressTask: Task<Void, Never>?
    private var settingsTask: Task<Void, any Error>?
    private var settingsTasks: [UUID: Task<Void, any Error>] = [:]
    private var authenticationTasks: [UUID: Task<AcquiredCredential, any Error>] = [:]
    var settingsRevision = 0
    var committedSettingsRevision = 0
    var settingsDraftRevision = 0
    var settingsSaveRevision = 0
    private var authenticationRevision = 0
    var stopped = false
    let lists: (any ResourceWatching)?
    let probe: (any ClusterProbing)?
    let namespaceListing: (any NamespaceListing)?
    /// Monotonic seconds, never wall-clock dates, so a clock change or a sleep/wake cannot make the
    /// namespace refresh throttle fire early or never.
    let monotonicNow: @Sendable () -> TimeInterval
    var namespaceFetches: [String: NamespaceFetch] = [:]
    var retiringNamespaceTasks: [UUID: Task<Void, Never>] = [:]
    var clusterGenerations: [String: UUID] = [:]
    var clusterTasks: [String: Task<Void, Never>] = [:]
    var retiringClusterTasks: [UUID: Task<Void, Never>] = [:]
    var listTask: Task<Void, Never>?
    let podMetricsListing: (any PodMetricsListing)?
    let metricsInterval: Duration
    var podMetricsTask: Task<Void, Never>?
    var retiringListTasks: [UUID: Task<Void, Never>] = [:]
    var listGeneration = UUID()
    var namespaceSelection = NamespaceSelection()
    let podDetails: (any PodDetailsProviding)?
    let deploymentDetails: (any DeploymentDetailsProviding)?
    let deploymentPods: (any DeploymentPodListing)?
    var podSelectionGeneration = UUID()
    var podLogSelectionGeneration = UUID()
    var podShellSelection: RowSelection?
    var podDetailTasks: [UUID: Task<Void, Never>] = [:]
    var podShellGuards: [UUID: RowSelection] = [:]
    let logs: (any LogStreaming)?
    var logTasks: [UUID: Task<Void, Never>] = [:]
    var logAttempts: [UUID: UUID] = [:]
    var podLogSelection: RowSelection?
    /// A deployment tab's current attempt, keyed by session: its own work is the resolution, which
    /// is the tab's rather than any one source's.
    var deploymentLogAttempts: [UUID: UUID] = [:]
    var podLogGuards: [UUID: RowSelection] = [:]
    /// The validated details behind an open logs menu, so confirming one needs no second request.
    var logChoices: [UUID: PodDetails] = [:]
    var shellChoices: [UUID: [PodDetails.Container]] = [:]

    public init(
        store: AppStore, exec: any ExecSessionControlling,
        authentication: any AuthenticationControlling, surfaces: any TerminalSurfaceCreating,
        browser: (any BrowserOpening)? = nil, configurations: (any AppConfigurationLoading)? = nil,
        lists: (any ResourceWatching)? = nil, podDetails: (any PodDetailsProviding)? = nil,
        deploymentDetails: (any DeploymentDetailsProviding)? = nil,
        deploymentPods: (any DeploymentPodListing)? = nil,
        logs: (any LogStreaming)? = nil, probe: (any ClusterProbing)? = nil,
        namespaces: (any NamespaceListing)? = nil,
        metrics: (any PodMetricsListing)? = nil,
        // Samples average over a window of roughly fifteen to forty-five seconds; polling faster only
        // re-reads the same numbers.
        metricsInterval: Duration = .seconds(15),
        monotonicNow: @escaping @Sendable () -> TimeInterval = {
            TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        }
    ) {
        self.store = store
        self.exec = exec
        self.authentication = authentication
        self.surfaces = surfaces
        self.browser = browser
        self.configurations = configurations
        self.lists = lists
        self.probe = probe
        namespaceListing = namespaces
        podMetricsListing = metrics
        self.metricsInterval = metricsInterval
        self.monotonicNow = monotonicNow
        self.podDetails = podDetails
        self.deploymentDetails = deploymentDetails
        self.deploymentPods = deploymentPods
        self.logs = logs
        progressTask = Task { [weak self, authentication] in
            let stream = await authentication.sessions()
            for await session in stream {
                guard !Task.isCancelled else { break }
                self?.receive(session)
            }
        }
    }

    public func updateAuthSettings(_ settings: AuthSettings) async throws {
        guard !stopped else { throw CancellationError() }
        try settings.validate()
        settingsRevision += 1
        let revision = settingsRevision
        let draftRevision = settingsDraftRevision
        let id = UUID()
        let previous = settingsTask
        let work = Task { [authentication] in
            _ = await previous?.result
            try Task.checkCancellation()
            try await authentication.update(settings: settings)
        }
        settingsTask = work
        settingsTasks[id] = work
        defer { settingsTasks.removeValue(forKey: id) }
        try await work.value
        guard !stopped, revision > committedSettingsRevision else { return }
        committedSettingsRevision = revision
        if revision == settingsRevision { settingsTask = nil }
        store.authSettings = settings
        if revision == settingsRevision, draftRevision == settingsDraftRevision { resetSettingsDraft(afterCommit: true) }
        refreshPluginPresentation()
    }

    public func signIn(context: ResolvedContext, useDeviceCode: Bool = false) async throws {
        let generation = listGeneration
        let credential = try await authenticate { [authentication] in
            try await authentication.signIn(for: context, useDeviceCode: useDeviceCode)
        }
        for session in store.execSessions where session.target.context == context { retryShell(session.id) }
        retryPodsAfterAuthentication(for: credential.identity, generation: generation)
    }

    public func retryAuthentication(operationID: UUID) async throws {
        let generation = listGeneration
        let credential = try await authenticate { [authentication] in
            try await authentication.retry(operationID: operationID)
        }
        retryPodsAfterAuthentication(for: credential.identity, generation: generation)
    }

    private func authenticate(_ operation: @escaping @Sendable () async throws -> AcquiredCredential) async throws -> AcquiredCredential {
        guard !stopped else { throw CancellationError() }
        authenticationRevision += 1
        let revision = authenticationRevision
        let id = UUID()
        let work = Task { try await operation() }
        authenticationTasks[id] = work
        defer { authenticationTasks.removeValue(forKey: id) }
        do {
            let credential = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            if !stopped, revision == authenticationRevision { store.authenticationDiagnostic = nil }
            return credential
        } catch {
            if !stopped, revision == authenticationRevision { store.authenticationDiagnostic = Self.authDiagnostic(error) }
            throw error
        }
    }

    public func cancelAuthentication(operationID: UUID) async {
        if var session = store.authenticationSessions[operationID] {
            session.transition(to: .cancelled)
            store.authenticationSessions[operationID] = session
        }
        await authentication.cancel(operationID: operationID)
    }

    private func receive(_ session: AuthSession) {
        guard !stopped, store.authenticationSessions[session.id]?.state.isTerminal != true else { return }
        if store.authenticationSessions[session.id] == nil { store.authenticationSessionOrder.append(session.id) }
        store.authenticationSessions[session.id] = session
        if store.authenticationSessions.count > 128,
           let oldest = store.authenticationSessionOrder.first(where: { store.authenticationSessions[$0]?.state.isTerminal == true }) {
            store.authenticationSessions.removeValue(forKey: oldest)
            store.authenticationSessionOrder.removeAll { $0 == oldest }
        }
    }

    deinit {
        presentationTask?.cancel()
        progressTask?.cancel()
        settingsTask?.cancel()
        for task in settingsTasks.values { task.cancel() }
        for task in authenticationTasks.values { task.cancel() }
        for task in tasks.values { task.cancel() }
        listTask?.cancel()
        podMetricsTask?.cancel()
        for task in retiringListTasks.values { task.cancel() }
        for task in clusterTasks.values { task.cancel() }
        for task in retiringClusterTasks.values { task.cancel() }
        for fetch in namespaceFetches.values { fetch.task?.cancel() }
        for task in retiringNamespaceTasks.values { task.cancel() }
        for task in podDetailTasks.values { task.cancel() }
        for task in logTasks.values { task.cancel() }
    }
}

public extension AppActions {
    @discardableResult
    func openShell(target: ExecTarget, containers: [PodDetails.Container] = []) -> UUID {
        let session = ExecSession(target: target, containers: containers)
        store.execSessions.append(session)
        store.sessionOrder.append(.shell(session.id))
        store.selectedSession = .shell(session.id)
        if stopped {
            finish(session.id, result: .cancelled)
        } else {
            start(session)
        }
        return session.id
    }

    func closeShell(_ id: UUID) {
        podShellGuards.removeValue(forKey: id)
        guard let index = index(id), !store.execSessions[index].isClosed else { return }
        store.execSessions[index].isClosed = true
        finish(id, result: .cancelled)
        attempts.removeValue(forKey: id)
        if let task = tasks.removeValue(forKey: id) {
            task.cancel()
            closingTasks[id] = Task { [weak self] in
                await task.value
                self?.closingTasks.removeValue(forKey: id)
            }
        }
        lifetimes.removeValue(forKey: id)?.close()
        store.surfaceRevision += 1
        store.sessionOrder.removeAll { $0 == .shell(id) }
        if store.selectedSession == .shell(id) { store.selectedSession = store.lastOpenSession }
    }

    func retryShell(_ id: UUID) {
        guard !stopped, let index = index(id), !store.execSessions[index].isClosed,
              case .finished(.failed(.authentication)) = store.execSessions[index].state else { return }
        do { try validatePodShell(id) } catch { closeShell(id); return }
        tasks.removeValue(forKey: id)?.cancel()
        store.execSessions[index].state = .authenticating
        start(store.execSessions[index])
    }
}

extension AppActions {
    /// Composition explicitly closes this owner, rather than relying on view dismantling.
    public func shutdown() {
        guard !stopped else { return }
        stopped = true
        cancelClusterWork()
        cancelNamespaceWork()
        cancelList()
        if store.connection != .idle { store.connection = .idle }
        for session in store.execSessions { closeShell(session.id) }
        for session in store.logSessions { closeLog(session.id) }
        progressTask?.cancel()
        progressTask = nil
        settingsTask?.cancel()
        settingsTask = nil
        for task in settingsTasks.values { task.cancel() }
        for task in authenticationTasks.values { task.cancel() }
        store.authenticationSessions = [:]
        store.authenticationSessionOrder = []
        store.authenticationDiagnostic = nil
        presentationRevision += 1
        configurationRevision += 1
        presentationTask?.cancel()
        presentationTask = nil
    }

    /// Local codes are intentionally not accepted as remote exit codes.
    public func childTerminated(_ id: UUID) async {
        guard let index = index(id), !store.execSessions[index].isClosed else { return }
        if !store.execSessions[index].state.isTerminal { await exec.childTerminated(sessionID: id) }
        lifetimes.removeValue(forKey: id)?.close()
        store.surfaceRevision += 1
        store.sessionOrder.removeAll { $0 == .shell(id) }
    }

    public func surface(for id: UUID) -> (any TerminalSurface)? { lifetimes[id]?.surface }

    public func acquireCredentials(context: ResolvedContext) async throws {
        let generation = listGeneration
        let credential = try await authenticate { [authentication] in
            try await authentication.acquire(for: context)
        }
        retryPodsAfterAuthentication(for: credential.identity, generation: generation)
    }

    /// A native termination delegate must await owned work before allowing the process to exit.
    public func shutdownAndWait() async {
        let pending = Array(tasks.values) + Array(closingTasks.values)
        let auth = Array(authenticationTasks.values)
        let settings = Array(settingsTasks.values)
        let progress = progressTask
        let presentation = presentationTask
        let podWork = Array(retiringListTasks.values) + [listTask, podMetricsTask].compactMap { $0 }
        let clusterWork = Array(clusterTasks.values) + Array(retiringClusterTasks.values)
            + namespaceFetches.values.compactMap(\.task) + Array(retiringNamespaceTasks.values)
        let detailWork = Array(podDetailTasks.values)
        let logWork = Array(logTasks.values)
        shutdown()
        async let authenticationDrain: Void = authentication.shutdown()
        for task in pending { await task.value }
        for task in auth { _ = await task.result }
        for task in settings { _ = await task.result }
        await progress?.value
        await presentation?.value
        for task in clusterWork { await task.value }
        for task in podWork { await task.value }
        for task in detailWork { await task.value }
        for task in logWork { await task.value }
        await authenticationDrain
    }
}
