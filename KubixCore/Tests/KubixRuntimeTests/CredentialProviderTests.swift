import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Test func providerStaticAndAnonymousDispatchNeverSpawnsProcess() async throws {
    let process = FakeProcess()
    let materials = MaterialFiles()
    let provider = CredentialProvider(resolver: testResolver(), runner: CredentialRunner(process: process), materials: materials)
    let token = try await provider.acquire(for: runtimeContext(user: KubeconfigUser(token: "static-synthetic")))
    #expect(token.entry?.credential.token == "static-synthetic")
    let anonymous = try await provider.acquire(for: runtimeContext(user: nil))
    #expect(anonymous.entry == nil)
    #expect(await process.requests().isEmpty)
    #expect(await materials.reads.isEmpty)
}

@Test func providerTokenFileRefreshAndReadErrors() async throws {
    let files = MaterialFiles(["/synthetic/token": Data("file-one\n".utf8)])
    let process = FakeProcess()
    let provider = CredentialProvider(resolver: testResolver(), runner: CredentialRunner(process: process), materials: files)
    let context = try runtimeContext(user: KubeconfigUser(tokenFile: "/synthetic/token"))
    let first = try await provider.acquire(for: context)
    #expect(first.entry?.credential.token == "file-one")
    await files.set("/synthetic/token", Data("file-two\n".utf8))
    let cached = try await provider.acquire(for: context)
    #expect(cached.entry?.credential.token == "file-one")
    await provider.invalidate(first.identity, failedGeneration: try #require(first.entry).generation)
    let second = try await provider.acquire(for: context)
    #expect(second.entry?.credential.token == "file-two")
    #expect(await files.reads.count == 2)
    await provider.invalidate(second.identity, failedGeneration: try #require(second.entry).generation)
    await files.set("/synthetic/token", nil)
    await #expect(throws: AuthenticationError.materialUnavailable) { try await provider.acquire(for: context) }
    #expect(await process.requests().isEmpty)
}

@Test(arguments: [Data(), Data([0xFF]), Data("bad token".utf8)])
func providerRejectsUnusableTokenFiles(bytes: Data) async throws {
    let files = MaterialFiles(["/token": bytes])
    let provider = CredentialProvider(resolver: testResolver(), materials: files)
    await #expect(throws: AuthError.self) {
        try await provider.acquire(for: runtimeContext(user: KubeconfigUser(tokenFile: "/token")))
    }
}

@Test func providerRejectsStaticAndCombinedExecCertificatesExplicitly() async throws {
    let process = FakeProcess { _, _ in
        ProcessResult(stdout: Data("""
        {"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential",
        "status":{"token":"synthetic-token","clientCertificateData":"cert","clientKeyData":"key"}}
        """.utf8), exitCode: 0)
    }
    let files = MaterialFiles()
    let provider = CredentialProvider(resolver: testResolver(), runner: CredentialRunner(process: process), materials: files)
    let context = try runtimeContext(user: KubeconfigUser(clientCertificate: "/cert", clientKey: "/key"))
    await #expect(throws: AuthenticationError.unsupportedCertificate) { try await provider.acquire(for: context) }
    #expect(await process.requests().isEmpty)
    #expect(await files.reads.isEmpty)
    await #expect(throws: AuthenticationError.unsupportedCertificate) { try await provider.acquire(for: runtimeContext()) }
    #expect(await process.requests().count == 1)
}

@Test func providerSingleFlightColdRefreshStale401AndShellReuse() async throws {
    let gate = TestGate()
    let process = FakeProcess { _, progress in
        progress("ready")
        try await gate.wait()
        return ProcessResult(stdout: syntheticCredential, exitCode: 0)
    }
    let provider = CredentialProvider(resolver: testResolver(), runner: CredentialRunner(process: process))
    let context = try runtimeContext()
    let progress = TextCapture()
    let requests = (0..<16).map { _ in
        Task { try await provider.acquire(for: context, progress: { _ in progress.append(".") }) }
    }
    defer { for request in requests { request.cancel() } }
    try await eventually { progress.value.count == 16 }
    #expect(await process.requests().count == 1)
    await gate.open()
    var first: AcquiredCredential?
    for request in requests {
        let credential = try await request.value
        if let first { #expect(credential.entry?.generation == first.entry?.generation) } else { first = credential }
    }
    let old = try #require(first)
    let generation = try #require(old.entry).generation
    await provider.invalidate(old.identity, failedGeneration: generation)
    let refreshed = try await withThrowingTaskGroup(of: AcquiredCredential.self) { group in
        for _ in 0..<16 {
            group.addTask {
                await provider.invalidate(old.identity, failedGeneration: generation)
                return try await provider.acquire(for: context)
            }
        }
        var results: [AcquiredCredential] = []
        for try await result in group { results.append(result) }
        return results
    }
    #expect(await process.requests().count == 2)
    let replacement = try #require(refreshed.first?.entry).generation
    #expect(replacement != generation)
    #expect(refreshed.allSatisfy { $0.entry?.generation == replacement })
    await provider.invalidate(old.identity, failedGeneration: generation)
    let shell = try await provider.acquire(for: runtimeContext(name: "a different shell context"))
    #expect(shell.entry?.generation == replacement)
    #expect(await process.requests().count == 2)
}

@Test func providerCancellationIsIsolatedBetweenSimultaneousWaiters() async throws {
    let gate = TestGate()
    let process = FakeProcess { _, progress in
        progress("ready")
        try await gate.wait()
        return ProcessResult(stdout: syntheticCredential, exitCode: 0)
    }
    let provider = CredentialProvider(resolver: testResolver(), runner: CredentialRunner(process: process))
    let context = try runtimeContext()
    let firstOutput = TextCapture()
    let secondOutput = TextCapture()
    let first = Task { try await provider.acquire(for: context, progress: firstOutput.append) }
    let second = Task { try await provider.acquire(for: context, progress: secondOutput.append) }
    defer { first.cancel(); second.cancel() }
    try await eventually { firstOutput.value == "ready" && secondOutput.value == "ready" }
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(await process.requests().count == 1)
    await gate.open()
    #expect(try await second.value.entry?.credential.token == "synthetic-credential-only")
    #expect(await process.requests().count == 1)
}

@Test func providerLastWaiterCancellationStopsUnderlyingAcquisition() async throws {
    let gate = TestGate()
    let output = TextCapture()
    let process = FakeProcess { _, progress in
        progress("ready")
        do { try await gate.wait() } catch { output.append("cancelled"); throw error }
        return ProcessResult(stdout: syntheticCredential, exitCode: 0)
    }
    let provider = CredentialProvider(resolver: testResolver(), runner: CredentialRunner(process: process))
    let first = Task { try await provider.acquire(for: runtimeContext(), progress: output.append) }
    try await eventually { output.value == "ready" }
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    try await eventually { output.value.contains("cancelled") }
}

final class RuntimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1_000
    func now() -> Date { lock.withLock { Date(timeIntervalSince1970: time) } }
    func set(_ time: TimeInterval) { lock.withLock { self.time = time } }
}

@Test func providerRefreshesOnClockSkewAndSettingsChanges() async throws {
    let clock = RuntimeClock()
    let process = FakeProcess { _, _ in
        ProcessResult(stdout: Data("""
        {"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential",
        "status":{"token":"synthetic-token","expirationTimestamp":"1970-01-01T00:20:00Z"}}
        """.utf8), exitCode: 0)
    }
    let resolver = testResolver()
    let provider = CredentialProvider(resolver: resolver, runner: CredentialRunner(process: process), now: clock.now)
    let context = try runtimeContext()
    let first = try await provider.acquire(for: context)
    clock.set(1_140)
    let refresh = try await provider.acquire(for: context)
    #expect(refresh.entry?.generation != first.entry?.generation)
    #expect(await process.requests().count == 2)
    _ = try await provider.acquire(for: context)
    #expect(await process.requests().count == 2)
    try await resolver.update(settings: AuthSettings(timeout: 700))
    let changed = try await provider.acquire(for: context)
    #expect(changed.identity != first.identity)
    #expect(await process.requests().count == 3)
}

@Test func sharedOperationCancelsOneWaiterButGlobalCancelAffectsAll() async throws {
    let gate = TestGate()
    let operation = SharedOperation<Int> { progress in
        progress("instructions")
        try await gate.wait()
        return 7
    }
    let first = Task { try await operation.value() }
    let second = Task { try await operation.value() }
    defer { first.cancel(); second.cancel() }
    try await eventually { operation.waiterCount == 2 }
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(operation.waiterCount == 1)
    operation.cancel()
    await #expect(throws: CancellationError.self) { try await second.value }
    #expect(operation.isFinished)
    let late = TextCapture()
    await #expect(throws: CancellationError.self) { try await operation.value(progress: late.append) }
    #expect(late.value.isEmpty)
}

@Test func sharedProgressCallbackCanCancelWithoutDeadlockOrLateInstructions() async throws {
    let gate = TestGate()
    let operation = SharedOperation<Int> { progress in
        progress("first")
        progress("must not be delivered")
        try await gate.wait()
        return 1
    }
    let capture = TextCapture()
    await #expect(throws: CancellationError.self) {
        try await operation.value { text in
            capture.append(text)
            operation.cancel()
        }
    }
    #expect(capture.value == "first")
}
