import Foundation
import KubixCore

func appContext(_ name: String = "first") throws -> ResolvedContext {
    try Kubeconfig(
        currentContext: name,
        clusters: [.init(name: name, cluster: .init(server: "https://\(name).synthetic.invalid"))],
        contexts: [.init(name: name, context: .init(cluster: name, namespace: "\(name)-namespace"))]
    ).resolve()
}

func appTarget(_ name: String = "first") throws -> ExecTarget {
    try ExecTarget(context: appContext(name), namespace: "explicit", pod: "pod", container: "regular")
}

@MainActor func appEventually(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw AppTestError.deadline }
        try await Task.sleep(for: .milliseconds(1))
    }
}

enum AppTestError: Error { case deadline, injected }

actor AppTestGate {
    private var opened = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var count: Int { waiters.count }

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if opened { return }
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: { Task { await self.cancel(id) } }
    }

    func open() {
        opened = true
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func cancelAll() {
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: CancellationError()) }
    }

    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}

actor AppTestCleanupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

actor AppTestAuth: AuthenticationControlling {
    let gate = AppTestGate()
    private(set) var acquisitions: [ResolvedContext] = []
    private(set) var signIns: [ResolvedContext] = []
    private(set) var settings: [AuthSettings] = []
    private(set) var cancellations: [UUID] = []
    private(set) var retries: [UUID] = []
    private var continuations: [UUID: AsyncStream<AuthSession>.Continuation] = [:]
    private var failure: (any Error)?
    private var signInGates: [String: AppTestGate] = [:]
    private var signInFailures: [String: AuthenticationError] = [:]
    let settingsGate: AppTestGate?
    let cleanupGate: AppTestCleanupGate?
    private let settingsFailures: Set<Int>
    private(set) var cleanupFinished = false
    var subscriberCount: Int { continuations.count }

    init(settingsGate: AppTestGate? = nil, settingsFailures: Set<Int> = [], cleanupGate: AppTestCleanupGate? = nil) {
        self.settingsGate = settingsGate
        self.settingsFailures = settingsFailures
        self.cleanupGate = cleanupGate
    }
    func fail(_ error: (any Error)?) { failure = error }
    func update(settings: AuthSettings) async throws {
        try settings.validate()
        self.settings.append(settings)
        if self.settings.count == 1 { try await settingsGate?.wait() }
        if settingsFailures.contains(self.settings.count) { throw AppTestError.injected }
    }

    func configureSignIn(_ name: String, gate: AppTestGate, failure: AuthenticationError? = nil) {
        signInGates[name] = gate
        signInFailures[name] = failure
    }

    func acquire(for context: ResolvedContext) async throws -> AcquiredCredential {
        acquisitions.append(context)
        do { try await gate.wait() } catch {
            if let cleanupGate { await cleanupGate.wait(); cleanupFinished = true }
            throw error
        }
        if let failure { throw failure }
        return try AcquiredCredential(identity: CredentialIdentity(from: context), entry: nil)
    }

    func signIn(for context: ResolvedContext, useDeviceCode: Bool) async throws -> AcquiredCredential {
        signIns.append(context)
        try await (signInGates[context.name] ?? gate).wait()
        if let failure = signInFailures[context.name] { throw failure }
        return try AcquiredCredential(identity: CredentialIdentity(from: context), entry: nil)
    }

    func sessions() -> AsyncStream<AuthSession> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AuthSession>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { _ in Task { await self.remove(id) } }
        return stream
    }

    func emit(_ session: AuthSession) { for continuation in continuations.values { continuation.yield(session) } }
    private func remove(_ id: UUID) { continuations.removeValue(forKey: id) }
    func cancel(operationID: UUID) async { cancellations.append(operationID); await gate.cancelAll() }
    func retry(operationID: UUID) throws -> AcquiredCredential {
        retries.append(operationID)
        return try AcquiredCredential(identity: CredentialIdentity(from: appContext()), entry: nil)
    }
}

actor AppTestExec: ExecSessionControlling {
    struct Run {
        let target: ExecTarget
        let ready: @MainActor @Sendable (ExecBridgeEndpoint) throws -> Void
        let update: @MainActor @Sendable (ExecSession.State) -> Void
        var continuation: CheckedContinuation<ExecSessionResult, Never>?
    }
    private(set) var runs: [UUID: Run] = [:]
    private(set) var children: [UUID] = []
    private(set) var ended: Set<UUID> = []
    let deferredReady: Bool

    init(deferredReady: Bool = false) { self.deferredReady = deferredReady }

    func run(
        sessionID: UUID, target: ExecTarget,
        ready: @escaping @MainActor @Sendable (ExecBridgeEndpoint) throws -> Void,
        update: @escaping @MainActor @Sendable (ExecSession.State) -> Void
    ) async -> ExecSessionResult {
        runs[sessionID] = Run(target: target, ready: ready, update: update)
        if !deferredReady {
            do { try await makeReady(sessionID) } catch { return .failed(.surface) }
        }
        return await withTaskCancellationHandler {
            let result = await withCheckedContinuation { runs[sessionID]?.continuation = $0 }
            ended.insert(sessionID)
            return result
        } onCancel: {
            if !self.deferredReady { Task { await self.complete(sessionID, .cancelled) } }
        }
    }

    func makeReady(_ id: UUID) async throws {
        guard let run = runs[id] else { throw AppTestError.injected }
        try await run.ready(ExecBridgeEndpoint(socketPath: "/local/session.sock", nonce: BridgeNonce(bytes: Data(repeating: 7, count: 32))))
        await run.update(.running)
    }

    func update(_ id: UUID, _ state: ExecSession.State) async { await runs[id]?.update(state) }

    func complete(_ id: UUID, _ result: ExecSessionResult) async {
        guard let run = runs[id], let continuation = run.continuation else { return }
        runs[id]?.continuation = nil
        await run.update(.finished(result))
        continuation.resume(returning: result)
    }

    func childTerminated(sessionID: UUID) async {
        children.append(sessionID)
        await complete(sessionID, .failed(.childTerminated))
    }
}

@MainActor final class AppTestSurface: TerminalSurface {
    var closes = 0
    let onChildExit: @MainActor @Sendable () -> Void
    init(onChildExit: @escaping @MainActor @Sendable () -> Void) { self.onChildExit = onChildExit }
    func teardown() { closes += 1; onChildExit() }
}

@MainActor final class AppTestSurfaces: TerminalSurfaceCreating {
    var created: [UUID: AppTestSurface] = [:]
    var failure = false
    func makeSurface(
        sessionID: UUID, target: ExecTarget, endpoint: ExecBridgeEndpoint,
        onChildExit: @escaping @MainActor @Sendable () -> Void
    ) throws -> any TerminalSurface {
        if failure { throw AppTestError.injected }
        let surface = AppTestSurface(onChildExit: onChildExit)
        created[sessionID] = surface
        return surface
    }
}
