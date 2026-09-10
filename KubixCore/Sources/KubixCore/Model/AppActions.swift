import Foundation

@MainActor
public final class AppActions {
    public let store: AppStore
    private let exec: any ExecSessionControlling
    let authentication: any AuthenticationControlling
    private let surfaces: any TerminalSurfaceCreating
    let browser: (any BrowserOpening)?
    let configurations: (any AppConfigurationLoading)?
    var presentationRevision = 0
    var configurationRevision = 0
    var presentationTask: Task<Void, Never>?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var closingTasks: [UUID: Task<Void, Never>] = [:]
    private var attempts: [UUID: UUID] = [:]
    private var lifetimes: [UUID: TerminalSurfaceLifetime] = [:]
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
    let pods: (any PodWatching)?
    var podTask: Task<Void, Never>?
    var retiringPodTasks: [UUID: Task<Void, Never>] = [:]
    var podGeneration = UUID()
    var namespaceSelection = NamespaceSelection()
    let podDetails: (any PodDetailsProviding)?
    var podSelectionGeneration = UUID()
    var podShellSelection: PodShellSelection?
    var podDetailTasks: [UUID: Task<Void, Never>] = [:]
    var podShellGuards: [UUID: PodShellSelection] = [:]
    let logs: (any LogStreaming)?
    var logTasks: [UUID: Task<Void, Never>] = [:]
    var logAttempts: [UUID: UUID] = [:]
    var podLogSelection: PodShellSelection?
    var podLogGuards: [UUID: PodShellSelection] = [:]

    public init(
        store: AppStore, exec: any ExecSessionControlling,
        authentication: any AuthenticationControlling, surfaces: any TerminalSurfaceCreating,
        browser: (any BrowserOpening)? = nil, configurations: (any AppConfigurationLoading)? = nil,
        pods: (any PodWatching)? = nil, podDetails: (any PodDetailsProviding)? = nil,
        logs: (any LogStreaming)? = nil
    ) {
        self.store = store
        self.exec = exec
        self.authentication = authentication
        self.surfaces = surfaces
        self.browser = browser
        self.configurations = configurations
        self.pods = pods
        self.podDetails = podDetails
        self.logs = logs
        progressTask = Task { [weak self, authentication] in
            let stream = await authentication.sessions()
            for await session in stream {
                guard !Task.isCancelled else { break }
                self?.receive(session)
            }
        }
    }

    @discardableResult
    public func openShell(target: ExecTarget) -> UUID {
        let session = ExecSession(target: target)
        store.execSessions.append(session)
        store.selectedExecSessionID = session.id
        store.selectedLogSessionID = nil
        if stopped {
            finish(session.id, result: .cancelled)
        } else {
            start(session)
        }
        return session.id
    }

    public func closeShell(_ id: UUID) {
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
        if store.selectedExecSessionID == id {
            store.selectedExecSessionID = store.execSessions.last(where: { !$0.isClosed })?.id
        }
    }

    public func retryShell(_ id: UUID) {
        guard !stopped, let index = index(id), !store.execSessions[index].isClosed,
              case .finished(.failed(.authentication)) = store.execSessions[index].state else { return }
        do { try validatePodShell(id) } catch { closeShell(id); return }
        tasks.removeValue(forKey: id)?.cancel()
        store.execSessions[index].state = .authenticating
        start(store.execSessions[index])
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
        let generation = podGeneration
        let credential = try await authenticate { [authentication] in
            try await authentication.signIn(for: context, useDeviceCode: useDeviceCode)
        }
        for session in store.execSessions where session.target.context == context { retryShell(session.id) }
        retryPodsAfterAuthentication(for: credential.identity, generation: generation)
    }

    public func retryAuthentication(operationID: UUID) async throws {
        let generation = podGeneration
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

    private func start(_ session: ExecSession) {
        let attempt = UUID()
        attempts[session.id] = attempt
        tasks[session.id] = Task { [weak self, authentication, exec] in
            let result: ExecSessionResult
            do {
                _ = try await authentication.acquire(for: session.target.context)
                try Task.checkCancellation()
                guard self?.isCurrent(session.id, attempt: attempt) == true else { return }
                try self?.validatePodShell(session.id)
                self?.update(session.id, state: .connecting)
                result = await exec.run(
                    sessionID: session.id, target: session.target,
                    ready: { [weak self] endpoint in
                        guard let self, self.isCurrent(session.id, attempt: attempt), !Task.isCancelled else {
                            throw CancellationError()
                        }
                        try self.validatePodShell(session.id)
                        try self.createSurface(session, endpoint: endpoint)
                    },
                    update: { [weak self] state in
                        guard self?.isCurrent(session.id, attempt: attempt) == true else { return }
                        self?.update(session.id, state: state)
                    }
                )
            } catch {
                result = error is CancellationError ? .cancelled : .failed(.authentication(Self.authDiagnostic(error)))
            }
            guard self?.isCurrent(session.id, attempt: attempt) == true else { return }
            self?.finish(session.id, result: result)
            self?.tasks.removeValue(forKey: session.id)
            self?.attempts.removeValue(forKey: session.id)
        }
    }

    private func createSurface(_ session: ExecSession, endpoint: ExecBridgeEndpoint) throws {
        let surface: any TerminalSurface
        do {
            surface = try surfaces.makeSurface(
                sessionID: session.id, target: session.target, endpoint: endpoint,
                onChildExit: { [weak self] in Task { await self?.childTerminated(session.id) } }
            )
        } catch { throw ExecFailure.surface }
        guard let index = index(session.id), !store.execSessions[index].isClosed else {
            surface.teardown()
            throw CancellationError()
        }
        lifetimes[session.id] = TerminalSurfaceLifetime(surface: surface)
        store.surfaceRevision += 1
    }

    private func index(_ id: UUID) -> Int? { store.execSessions.firstIndex { $0.id == id } }

    private func isCurrent(_ id: UUID, attempt: UUID) -> Bool {
        !stopped && attempts[id] == attempt && index(id).map { !store.execSessions[$0].isClosed } == true
    }

    private func update(_ id: UUID, state: ExecSession.State) {
        guard let index = index(id), !store.execSessions[index].state.isTerminal else { return }
        if state == .running { podShellGuards.removeValue(forKey: id) }
        store.execSessions[index].state = state
    }

    private func finish(_ id: UUID, result: ExecSessionResult) { update(id, state: .finished(result)) }

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
        podTask?.cancel()
        for task in retiringPodTasks.values { task.cancel() }
        for task in podDetailTasks.values { task.cancel() }
        for task in logTasks.values { task.cancel() }
    }
}

extension AppActions {
    /// Composition explicitly closes this owner, rather than relying on view dismantling.
    public func shutdown() {
        guard !stopped else { return }
        stopped = true
        cancelPods()
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
    }

    public func surface(for id: UUID) -> (any TerminalSurface)? { lifetimes[id]?.surface }

    public func acquireCredentials(context: ResolvedContext) async throws {
        let generation = podGeneration
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
        let podWork = Array(retiringPodTasks.values) + (podTask.map { [$0] } ?? [])
        let detailWork = Array(podDetailTasks.values)
        let logWork = Array(logTasks.values)
        shutdown()
        async let authenticationDrain: Void = authentication.shutdown()
        for task in pending { await task.value }
        for task in auth { _ = await task.result }
        for task in settings { _ = await task.result }
        await progress?.value
        await presentation?.value
        for task in podWork { await task.value }
        for task in detailWork { await task.value }
        for task in logWork { await task.value }
        await authenticationDrain
    }

    static func authDiagnostic(_ error: any Error) -> String {
        if let error = error as? AuthenticationError { return error.errorDescription ?? "Authentication failed." }
        if let error = error as? AuthError { return error.description }
        if let error = error as? any AuthenticationDiagnosticProviding { return error.authenticationDiagnostic }
        if error is CancellationError { return "Authentication was cancelled." }
        return "Authentication failed. Check the configured plugin/profile and explicitly retry."
    }
}
