import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

/// Cancellation starts cleanup, but only the test can finish it. This models a process runner
/// still draining descriptors/reaping its child after its requester has already cancelled.
final class GatedAuthCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private let running = TestGate()
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var cleaning = false
    private var finished = false
    var started: Bool { lock.withLock { entered } }
    var isCleaning: Bool { lock.withLock { cleaning } }
    var isFinished: Bool { lock.withLock { finished } }

    func run() async throws {
        lock.withLock { entered = true }
        do { try await running.wait() } catch {
            await withCheckedContinuation { pending in
                let ready = lock.withLock {
                    cleaning = true
                    if released { return true }
                    continuation = pending
                    return false
                }
                if ready { pending.resume() }
            }
            lock.withLock { finished = true }
            throw error
        }
    }

    func release() {
        let pending = lock.withLock {
            released = true
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume()
    }
}

private func assertShutdownPending(
    _ cleanup: GatedAuthCleanup, _ shutdown: TextCapture
) async throws {
    try await eventually { cleanup.isCleaning && shutdown.value.contains("started") }
    try await Task.sleep(for: .milliseconds(30))
    #expect(!cleanup.isFinished)
    #expect(shutdown.value == "started")
}

@Suite @MainActor struct AuthenticationShutdownTests {
    @Test func providerJoinsCancelledWorkerAfterSameIdentityReplacement() async throws {
        let cleanup = GatedAuthCleanup()
        defer { cleanup.release() }
        let count = InvocationCount()
        let process = FakeProcess { _, _ in
            if await count.next() == 1 { try await cleanup.run() }
            return .init(stdout: syntheticCredential, exitCode: 0)
        }
        let provider = CredentialProvider(resolver: testResolver(), runner: CredentialRunner(process: process))
        let context = try runtimeContext()
        let settled = TextCapture()
        let requester = Task {
            defer { settled.append("settled") }
            return try await provider.acquire(for: context)
        }
        defer { requester.cancel() }
        try await eventually { cleanup.started }
        requester.cancel()
        try await eventually { settled.value == "settled" && cleanup.isCleaning }
        await #expect(throws: CancellationError.self) { try await requester.value }
        #expect(try await provider.acquire(for: context).entry?.credential.token == "synthetic-credential-only")
        let status = TextCapture()
        let shutdown = Task { status.append("started"); await provider.shutdown(); status.append("finished") }
        try await assertShutdownPending(cleanup, status)
        await #expect(throws: CancellationError.self) { try await provider.acquire(for: context) }
        cleanup.release()
        await shutdown.value
        await provider.shutdown()
        #expect(cleanup.isFinished && status.value == "startedfinished")
        #expect(await process.requests().count == 2)
    }

    @Test func loginJoinsRetiredWorkerWithoutCancellingAnotherWaiter() async throws {
        let cleanup = GatedAuthCleanup()
        defer { cleanup.release() }
        let count = InvocationCount()
        let process = FakeProcess { request, progress in
            if request.arguments == ["--version"] { return .init(stdout: Data("aws-cli/2.synthetic".utf8), exitCode: 0) }
            progress("ready")
            if await count.next() == 1 { try await cleanup.run() }
            return .init(stdout: Data(), exitCode: 0)
        }
        let login = AWSLoginService(runner: process)
        let binding = try await loginBinding()
        let firstText = TextCapture()
        let secondText = TextCapture()
        let first = Task { try await login.login(binding, progress: firstText.append) }
        let second = Task { try await login.login(binding, progress: secondText.append) }
        defer { first.cancel(); second.cancel() }
        try await eventually { firstText.value == "ready" && secondText.value == "ready" }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(!cleanup.isCleaning)
        await login.cancel(binding)
        await #expect(throws: CancellationError.self) { try await second.value }
        try await eventually { cleanup.isCleaning }
        try await login.login(binding)
        let status = TextCapture()
        let shutdown = Task { status.append("started"); await login.shutdown(); status.append("finished") }
        try await assertShutdownPending(cleanup, status)
        await #expect(throws: CancellationError.self) { try await login.login(binding) }
        cleanup.release()
        await shutdown.value
        #expect(cleanup.isFinished)
        #expect(await process.requests().count == 4)
    }

    @Test(arguments: [false, true])
    func appShutdownDrainsRetiredAcquisitionOrBrowserLogin(browser: Bool) async throws {
        let cleanup = GatedAuthCleanup()
        defer { cleanup.release() }
        let process = FakeProcess { request, _ in
            if request.arguments == ["--version"] { return .init(stdout: Data("aws-cli/2.synthetic".utf8), exitCode: 0) }
            try await cleanup.run()
            return .init(stdout: syntheticCredential, exitCode: 0)
        }
        let (authentication, provider) = orchestration(process: process)
        let context = try awsContext()
        let actions = AppActions(
            store: AppStore(contexts: [context]), exec: PodShellExec(),
            authentication: authentication, surfaces: PodShellSurfaces()
        )
        defer { actions.shutdown() }
        let settled = TextCapture()
        let requester = Task {
            defer { settled.append("settled") }
            if browser { try await actions.signIn(context: context) } else { try await actions.acquireCredentials(context: context) }
        }
        defer { requester.cancel() }
        try await eventually { cleanup.started }
        requester.cancel()
        try await eventually { settled.value == "settled" && cleanup.isCleaning }
        await #expect(throws: CancellationError.self) { try await requester.value }
        let status = TextCapture()
        let shutdown = Task { status.append("started"); await actions.shutdownAndWait(); status.append("finished") }
        try await assertShutdownPending(cleanup, status)
        await #expect(throws: CancellationError.self) { try await authentication.acquire(for: context) }
        await #expect(throws: CancellationError.self) { try await authentication.signIn(for: context) }
        await #expect(throws: CancellationError.self) { try await provider.acquire(for: context) }
        let repeated = Task { await actions.shutdownAndWait() }
        cleanup.release()
        await shutdown.value
        await repeated.value
        #expect(cleanup.isFinished && actions.store.authenticationSessions.isEmpty)
        #expect(await process.requests().count == (browser ? 2 : 1))
        var sessions = await authentication.sessions().makeAsyncIterator()
        #expect(await sessions.next() == nil)
    }

    @Test func authenticationJoinsCancelledWorkerAcrossBoundedRetryHistory() async throws {
        let cleanup = GatedAuthCleanup()
        defer { cleanup.release() }
        let deadline = FirstGatedDeadline(cleanup: cleanup)
        let service = AuthenticationService(provider: CredentialProvider(resolver: testResolver()), deadline: deadline)
        let context = try runtimeContext(user: .init(token: "synthetic"))
        let capture = SessionCapture()
        let observer = observe(service, in: capture)
        defer { observer.cancel() }
        let requester = Task { try await service.acquire(for: context) }
        defer { requester.cancel() }
        try await eventually { cleanup.isCleaning && !capture.values.isEmpty }
        let id = try #require(capture.values.first?.id)
        await service.cancel(operationID: id)
        await #expect(throws: CancellationError.self) { try await requester.value }
        // Exercise bounded terminal-history eviction while old worker cleanup is still held.
        for _ in 0..<130 { _ = try await service.acquire(for: context) }
        let status = TextCapture()
        let shutdown = Task { status.append("started"); await service.shutdown(); status.append("finished") }
        try await assertShutdownPending(cleanup, status)
        await #expect(throws: CancellationError.self) { try await service.retry(operationID: id) }
        cleanup.release()
        await shutdown.value
        await observer.value
        #expect(cleanup.isFinished)
    }

    @Test func appShutdownClosesResolverAndJoinsCancelledPATHDiscovery() async throws {
        let cleanup = GatedAuthCleanup()
        defer { cleanup.release() }
        let process = FakeProcess { _, _ in
            try await cleanup.run()
            return .init(stdout: Data(), exitCode: 0)
        }
        let resolver = PluginResolver(
            environment: ["SHELL": "/synthetic/shell"], store: MemoryAuthSettingsStore(),
            shell: ShellPath(runner: process), files: Executables()
        )
        let (authentication, _) = orchestration(process: FakeProcess(), resolver: resolver)
        let context = try runtimeContext()
        let actions = AppActions(
            store: AppStore(contexts: [context]), exec: PodShellExec(),
            authentication: authentication, surfaces: PodShellSurfaces()
        )
        defer { actions.shutdown() }
        let requester = Task { try await actions.acquireCredentials(context: context) }
        defer { requester.cancel() }
        try await eventually { cleanup.started }
        let status = TextCapture()
        let shutdown = Task { status.append("started"); await actions.shutdownAndWait(); status.append("finished") }
        try await assertShutdownPending(cleanup, status)
        await #expect(throws: CancellationError.self) { try await requester.value }
        await #expect(throws: CancellationError.self) { try await resolver.resolve(runtimeExec()) }
        cleanup.release()
        await shutdown.value
        #expect(cleanup.isFinished && status.value == "startedfinished")
        #expect(await process.requests().count == 1)
    }

    @Test func resolverReplacesCancelledBaselineButJoinsRetiredCleanup() async throws {
        let cleanup = GatedAuthCleanup()
        defer { cleanup.release() }
        let count = InvocationCount()
        let process = FakeProcess { _, _ in
            if await count.next() == 1 { try await cleanup.run() }
            return .init(stdout: Data("\u{1e}/tools\u{1f}".utf8), exitCode: 0)
        }
        let resolver = PluginResolver(
            environment: ["SHELL": "/synthetic/shell"], store: MemoryAuthSettingsStore(),
            shell: ShellPath(runner: process), files: Executables()
        )
        let requester = Task { try await resolver.resolve(runtimeExec()) }
        defer { requester.cancel() }
        try await eventually { cleanup.started }
        requester.cancel()
        await #expect(throws: CancellationError.self) { try await requester.value }
        #expect(try await resolver.resolve(runtimeExec()).executable.path == "/tools/plugin")
        let status = TextCapture()
        let shutdown = Task { status.append("started"); await resolver.shutdown(); status.append("finished") }
        try await assertShutdownPending(cleanup, status)
        cleanup.release()
        await shutdown.value
        #expect(cleanup.isFinished)
        #expect(await process.requests().count == 2)
    }
}

private actor FirstGatedDeadline: AuthDeadlineWaiting {
    let cleanup: GatedAuthCleanup
    private var calls = 0
    init(cleanup: GatedAuthCleanup) { self.cleanup = cleanup }
    func wait(seconds: TimeInterval) async throws {
        calls += 1
        if calls == 1 { try await cleanup.run() } else { try await Task.sleep(for: .seconds(seconds)) }
    }
}
