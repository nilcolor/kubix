import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

final class SessionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [AuthSession] = []
    var values: [AuthSession] { lock.withLock { snapshots } }
    func append(_ session: AuthSession) { lock.withLock { snapshots.append(session) } }
}

func observe(_ service: AuthenticationService, in capture: SessionCapture) -> Task<Void, Never> {
    Task {
        for await session in await service.sessions() { capture.append(session) }
    }
}

func orchestration(
    process: any ProcessRunning, resolver: PluginResolver = testResolver()
) -> (AuthenticationService, CredentialProvider) {
    let provider = CredentialProvider(resolver: resolver, runner: CredentialRunner(process: process))
    return (AuthenticationService(provider: provider, login: AWSLoginService(runner: process)), provider)
}

@Test func authenticationFailureNeverAutomaticallyStartsBrowserLogin() async throws {
    let process = FakeProcess { _, progress in
        progress("synthetic transient plugin instruction")
        return ProcessResult(stdout: Data("synthetic-credential-only".utf8), exitCode: 17)
    }
    let (service, _) = orchestration(process: process)
    let capture = SessionCapture()
    let observer = observe(service, in: capture)
    defer { observer.cancel() }
    await #expect(throws: ProcessFailure.exited(17)) { try await service.acquire(for: awsContext()) }
    try await eventually { capture.values.contains { $0.state == .failed } }
    #expect(await process.requests().count == 1)
    let terminal = try #require(capture.values.last)
    #expect(terminal.instructions.isEmpty)
    #expect(terminal.diagnostic?.contains("17") == true)
    #expect(terminal.profile == "dev")
    #expect(capture.values.allSatisfy { !$0.instructions.contains("synthetic-credential-only") })
    await #expect(throws: ProcessFailure.exited(17)) { try await service.retry(operationID: terminal.id) }
    #expect(await process.requests().count == 2)
    #expect(await process.requests().allSatisfy { $0.arguments.contains("get-token") })
}

@Test func actualBrowserLoginThenGetTokenUsesSameExecutableAndClearsInstructions() async throws {
    let workspace = try StubWorkspace()
    let provider = CredentialProvider(resolver: workspace.resolver(mode: "success"))
    let service = AuthenticationService(provider: provider)
    let capture = SessionCapture()
    let observer = observe(service, in: capture)
    defer { observer.cancel() }
    let context = try awsContext()
    let initial = try await service.acquire(for: context)
    let authenticated = try await service.signIn(for: context, useDeviceCode: false)
    #expect(authenticated.entry?.credential.token == "synthetic-credential-only")
    #expect(authenticated.entry?.generation != initial.entry?.generation)
    try await eventually { capture.values.filter { $0.state == .succeeded }.count == 2 }
    #expect(capture.values.contains { $0.instructions.contains("synthetic-login") })
    #expect(capture.values.contains { $0.instructions.contains("SYNTHETIC-CODE") })
    let terminal = try #require(capture.values.last)
    #expect(terminal.instructions.isEmpty)
    #expect(terminal.profile == "dev")
    #expect(terminal.state == .succeeded)
    #expect(!capture.values.contains { $0.instructions.contains("synthetic-credential-only") })
}

@Test func actualSuccessfulLoginFollowedByAcquisitionErrorIsNotSuccessOrLoop() async throws {
    let workspace = try StubWorkspace()
    let service = AuthenticationService(provider: CredentialProvider(resolver: workspace.resolver(mode: "nonzero")))
    let capture = SessionCapture()
    let observer = observe(service, in: capture)
    defer { observer.cancel() }
    await #expect(throws: ProcessFailure.exited(17)) { try await service.signIn(for: awsContext(), useDeviceCode: true) }
    try await eventually { capture.values.last?.state == .failed }
    #expect(!capture.values.contains { $0.state == .succeeded })
    #expect(capture.values.last?.instructions.isEmpty == true)
    #expect(capture.values.last?.diagnostic?.contains("17") == true)
}

@Test func sharedBrowserLoginReacquiresOnceAndCallerCancellationIsIsolated() async throws {
    let gate = TestGate()
    let process = FakeProcess { request, progress in
        if request.arguments == ["--version"] {
            return ProcessResult(stdout: Data("aws-cli/2.99".utf8), exitCode: 0)
        }
        if request.arguments.first == "sso" {
            progress("https://synthetic.invalid/login")
            try await gate.wait()
            return ProcessResult(stdout: Data("success".utf8), exitCode: 0)
        }
        return ProcessResult(stdout: syntheticCredential, exitCode: 0)
    }
    let (service, _) = orchestration(process: process)
    let capture = SessionCapture()
    let observer = observe(service, in: capture)
    defer { observer.cancel() }
    let context = try awsContext()
    let first = Task { try await service.signIn(for: context, useDeviceCode: false) }
    defer { first.cancel() }
    try await eventually { capture.values.contains { $0.instructions.contains("https://") } }
    let id = try #require(capture.values.last?.id)
    let others = (0..<12).map { _ in Task { try await service.signIn(for: context, useDeviceCode: false) } }
    defer { for other in others { other.cancel() } }
    try await eventually { await service.waiterCount(operationID: id) == 13 }
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(await process.requests().count == 2)
    // A normal transport/shell acquisition also joins the existing browser operation.
    let shell = Task { try await service.acquire(for: context) }
    defer { shell.cancel() }
    try await eventually { await service.waiterCount(operationID: id) == 13 }
    await gate.open()
    let shellResult = try await shell.value
    for other in others { #expect(try await other.value.entry?.generation == shellResult.entry?.generation) }
    #expect(await process.requests().count == 3)
    try await eventually { capture.values.last?.state == .succeeded }
    #expect(capture.values.last?.id == id)
    #expect(capture.values.last?.instructions.isEmpty == true)
}

@Test func loginAcrossIdentitiesGlobalCancelAndExplicitRetry() async throws {
    let gate = TestGate()
    let process = FakeProcess { request, progress in
        if request.arguments == ["--version"] { return ProcessResult(stdout: Data("aws-cli/2.99".utf8), exitCode: 0) }
        if request.arguments.first == "sso" {
            progress("waiting for browser")
            try await gate.wait()
            return ProcessResult(stdout: Data(), exitCode: 0)
        }
        return ProcessResult(stdout: syntheticCredential, exitCode: 0)
    }
    let (service, _) = orchestration(process: process)
    let capture = SessionCapture()
    let observer = observe(service, in: capture)
    defer { observer.cancel() }
    let firstContext = try awsContext()
    let secondContext = try awsContext(server: "https://other.synthetic.invalid")
    let first = Task { try await service.signIn(for: firstContext, useDeviceCode: true) }
    defer { first.cancel() }
    try await eventually { capture.values.contains { $0.instructions == "waiting for browser" } }
    let firstID = try #require(capture.values.last?.id)
    // A different identity must wait for the same profile's login, not acquire a token prematurely.
    let second = Task { try await service.acquire(for: secondContext) }
    defer { second.cancel() }
    try await eventually { Set(capture.values.filter { !$0.instructions.isEmpty }.map(\.id)).count == 2 }
    #expect(await process.requests().count == 2)
    await service.cancel(operationID: firstID)
    await #expect(throws: CancellationError.self) { try await first.value }
    await #expect(throws: CancellationError.self) { try await second.value }
    try await eventually { Set(capture.values.filter { $0.state == .cancelled }.map(\.id)).count == 2 }
    #expect(capture.values.filter { $0.state == .cancelled }.allSatisfy { $0.instructions.isEmpty })
    #expect(await process.requests().count == 2)
    let retry = Task { try await service.retry(operationID: firstID) }
    defer { retry.cancel() }
    try await eventually { await process.requests().count == 4 }
    let calls = await process.requests()
    #expect(calls.last?.arguments.contains("--use-device-code") == true)
    // Cancelling a terminal operation must not cancel its newer retry.
    await service.cancel(operationID: firstID)
    await gate.open()
    #expect(try await retry.value.entry?.credential.token == "synthetic-credential-only")
    #expect(await process.requests().count == 5)
    try await eventually { capture.values.last?.state == .succeeded }
    #expect(capture.values.last?.id != firstID)
}

@Test func authSessionSubscribersCanUnsubscribeWithoutCancellingLogin() async throws {
    let workspace = try StubWorkspace()
    let service = AuthenticationService(provider: CredentialProvider(resolver: workspace.resolver(mode: "login-wait")))
    let firstCapture = SessionCapture()
    let secondCapture = SessionCapture()
    let firstObserver = observe(service, in: firstCapture)
    let secondObserver = observe(service, in: secondCapture)
    defer { firstObserver.cancel(); secondObserver.cancel() }
    let task = Task { try await service.signIn(for: awsContext(), useDeviceCode: false) }
    defer { task.cancel(); workspace.release() }
    try await eventually {
        firstCapture.values.contains { $0.instructions.contains("SYNTHETIC-CODE") }
            && secondCapture.values.contains { $0.instructions.contains("SYNTHETIC-CODE") }
    }
    firstObserver.cancel()
    workspace.release()
    _ = try await task.value
    try await eventually { secondCapture.values.last?.state == .succeeded }
    #expect(secondCapture.values.last?.instructions.isEmpty == true)
}

@Test func loginBarrierWaitsForOldAcquisitionThenRefreshesExactlyOnce() async throws {
    let oldGate = TestGate()
    let callCount = InvocationCount()
    let process = FakeProcess { request, progress in
        if request.arguments == ["--version"] { return ProcessResult(stdout: Data("aws-cli/2.99".utf8), exitCode: 0) }
        if request.arguments.first == "sso" { return ProcessResult(stdout: Data(), exitCode: 0) }
        let index = await callCount.next()
        if index == 1 {
            progress("old acquisition waiting")
            try await oldGate.wait()
        }
        return ProcessResult(stdout: syntheticCredential, exitCode: 0)
    }
    let (service, _) = orchestration(process: process)
    let capture = SessionCapture()
    let observer = observe(service, in: capture)
    defer { observer.cancel() }
    let context = try awsContext()
    let old = Task { try await service.acquire(for: context) }
    defer { old.cancel() }
    try await eventually { capture.values.contains { $0.instructions == "old acquisition waiting" } }
    let login = Task { try await service.signIn(for: context, useDeviceCode: false) }
    defer { login.cancel() }
    try await eventually { await process.requests().count == 3 }
    await oldGate.open()
    let first = try await old.value
    let refreshed = try await login.value
    #expect(first.entry?.generation != refreshed.entry?.generation)
    #expect(await process.requests().count == 4)
}

actor InvocationCount {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

@Test func authenticationTimeoutClearsInstructionsAndRequiresExplicitRetry() async throws {
    let workspace = try StubWorkspace()
    let service = AuthenticationService(provider: CredentialProvider(resolver: workspace.resolver(mode: "login-wait", timeout: 0.2)))
    let capture = SessionCapture()
    let observer = observe(service, in: capture)
    defer { observer.cancel() }
    await #expect(throws: ProcessFailure.timedOut) { try await service.signIn(for: awsContext(), useDeviceCode: false) }
    try await eventually { capture.values.last?.state == .failed }
    #expect(capture.values.last?.instructions.isEmpty == true)
    #expect(capture.values.last?.diagnostic?.contains("timed out") == true)
    #expect(Set(capture.values.map(\.id)).count == 1)
}

actor ControlledAuthDeadline: AuthDeadlineWaiting {
    let expired = TestGate()
    private(set) var budgets: [TimeInterval] = []
    func wait(seconds: TimeInterval) async throws {
        budgets.append(seconds)
        try await expired.wait()
    }
}

@Test func oneConfigurableAuthDeadlineCoversLoginAndPostLoginAcquisition() async throws {
    let acquisition = TestGate()
    let cancelled = TextCapture()
    let process = FakeProcess { request, _ in
        if request.arguments == ["--version"] { return ProcessResult(stdout: Data("aws-cli/2.99".utf8), exitCode: 0) }
        if request.arguments.first == "sso" { return ProcessResult(stdout: Data(), exitCode: 0) }
        do { try await acquisition.wait() } catch { cancelled.append("stopped"); throw error }
        return ProcessResult(stdout: syntheticCredential, exitCode: 0)
    }
    let provider = CredentialProvider(
        resolver: testResolver(settings: AuthSettings(timeout: 900)), runner: CredentialRunner(process: process)
    )
    let clock = ControlledAuthDeadline()
    let service = AuthenticationService(provider: provider, login: AWSLoginService(runner: process), deadline: clock)
    let task = Task { try await service.signIn(for: awsContext(), useDeviceCode: false) }
    defer { task.cancel() }
    try await eventually { await process.requests().count == 3 }
    try await eventually { await clock.budgets == [900] }
    #expect(await clock.budgets == [900])
    await clock.expired.open()
    await #expect(throws: ProcessFailure.timedOut) { try await task.value }
    try await eventually { cancelled.value == "stopped" }
    #expect(await process.requests().count == 3)
}
