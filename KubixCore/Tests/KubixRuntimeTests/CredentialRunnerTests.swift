import Darwin
import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Test func waitingProcessesDoNotOccupyCooperativeExecutor() async throws {
    let workspace = try StubWorkspace()
    let plugin = try await workspace.resolver(mode: "wait").resolve(runtimeExec())
    let context = try runtimeContext()
    let progress = TextCapture()
    let count = min(32, max(16, ProcessInfo.processInfo.activeProcessorCount * 2))
    let calls = (0..<count).map { _ in
        Task {
            try await CredentialRunner().acquire(context: context, plugin: plugin) { _ in progress.append(".") }
        }
    }
    defer { for call in calls { call.cancel() } }
    try await eventually { progress.value.count == count }
    for call in calls { call.cancel() }
    for call in calls {
        await #expect(throws: CancellationError.self) { try await call.value }
    }
    #expect(progress.value.count == count)
}

@Test func credentialRunnerFakeVerifiesArgvEnvironmentAndExecInfoPolicy() async throws {
    let config = runtimeExec(args: ["space ; $(not-a-command)"], env: [
        ExecEnvironmentVariable(name: "FIXTURE_VALUE", value: "kubeconfig"),
        ExecEnvironmentVariable(name: "KUBERNETES_EXEC_INFO", value: "must-be-overwritten")
    ])
    let context = try runtimeContext(user: KubeconfigUser(exec: config))
    let plugin = try await testResolver(environment: ["FIXTURE_VALUE": "inherited"]).resolve(config)
    let fake = FakeProcess { request, progress in
        #expect(request.arguments == ["space ; $(not-a-command)"])
        #expect(request.executable.path == "/tools/plugin")
        #expect(request.environment["FIXTURE_VALUE"] == "kubeconfig")
        let info = try #require(request.environment["KUBERNETES_EXEC_INFO"]).data(using: .utf8)!
        let json = try #require(JSONSerialization.jsonObject(with: info) as? [String: Any])
        let spec = try #require(json["spec"] as? [String: Any])
        #expect(spec["interactive"] as? Bool == false)
        #expect(request.output == .credential)
        #expect(request.timeout == 600)
        progress("synthetic live instruction")
        return ProcessResult(stdout: syntheticCredential, exitCode: 0)
    }
    let output = TextCapture()
    let result = try await CredentialRunner(process: fake).acquire(context: context, plugin: plugin, progress: output.append)
    #expect(result.token == "synthetic-credential-only")
    #expect(output.value == "synthetic live instruction")
    #expect(!output.value.contains("synthetic-credential-only"))
}

@Test(arguments: ["Never", "IfAvailable"])
func actualRunnerClosedStdinAndLiteralArguments(mode: String) async throws {
    let workspace = try StubWorkspace()
    let resolver = workspace.resolver(mode: "arguments")
    let config = runtimeExec(args: ["space ; $(not-a-command)"], env: [
        ExecEnvironmentVariable(name: "FIXTURE_VALUE", value: "kubeconfig")
    ], mode: mode)
    let context = try runtimeContext(user: KubeconfigUser(exec: config))
    let plugin = try await resolver.resolve(config)
    let credential = try await CredentialRunner().acquire(context: context, plugin: plugin, progress: { _ in })
    #expect(credential.token == "synthetic-credential-only")
}

@Test func credentialRunnerRejectsAlwaysBeforeProcessLaunch() async throws {
    let config = runtimeExec(mode: "Always")
    let context = try runtimeContext(user: KubeconfigUser(exec: config))
    let fake = FakeProcess()
    let plugin = try await testResolver().resolve(config)
    await #expect(throws: AuthError.interactiveInputRequired) {
        try await CredentialRunner(process: fake).acquire(context: context, plugin: plugin, progress: { _ in })
    }
    #expect(await fake.requests().isEmpty)
}

@Test func actualRunnerEmitsUnicodePromptBeforeNewlineOrEOFWithoutCredentialStdout() async throws {
    let workspace = try StubWorkspace()
    let context = try runtimeContext()
    let plugin = try await workspace.resolver(mode: "prompt").resolve(runtimeExec())
    let output = TextCapture()
    let task = Task { try await CredentialRunner().acquire(context: context, plugin: plugin, progress: output.append) }
    defer { workspace.release(); task.cancel() }
    try await eventually { output.value.contains("https://synthetic.invalid/authorize") }
    #expect(output.value == "€ Open https://synthetic.invalid/authorize")
    workspace.release()
    let result = try await task.value
    #expect(result.token == "synthetic-credential-only")
    #expect(!output.value.contains("synthetic-credential-only"))
}

@Test func actualRunnerDrainsStderrPressureWhileStdoutWaitsForEOF() async throws {
    let workspace = try StubWorkspace()
    let plugin = try await workspace.resolver(mode: "pressure").resolve(runtimeExec())
    let output = TextCapture()
    let result = try await CredentialRunner().acquire(context: runtimeContext(), plugin: plugin, progress: output.append)
    #expect(result.token == "synthetic-credential-only")
    #expect(output.value.utf8.count > 900_000)
    #expect(!output.value.contains("synthetic-credential-only"))
}

@Test(arguments: ["nonzero", "malformed", "mismatch", "expired", "certificates", "overflow"])
func actualRuntimeRejectsBadOutputsWithoutLeakingStdout(mode: String) async throws {
    let workspace = try StubWorkspace()
    let provider = CredentialProvider(resolver: workspace.resolver(mode: mode))
    let output = TextCapture()
    do {
        _ = try await provider.acquire(for: runtimeContext(), progress: output.append)
        Issue.record("Expected rejection")
    } catch {
        #expect(!String(describing: error).contains("synthetic-credential-only"))
        #expect(!output.value.contains("synthetic-credential-only"))
        switch mode {
        case "nonzero": #expect(error as? ProcessFailure == .exited(17))
        case "malformed": #expect(error as? AuthError == .malformedExecCredential)
        case "mismatch": #expect(error as? AuthError == .outputVersionMismatch)
        case "expired": #expect(error as? AuthError == .expiredCredential)
        case "certificates": #expect(error as? AuthenticationError == .unsupportedCertificate)
        default: #expect(error as? ProcessFailure == .outputLimit)
        }
    }
}

@Test func actualRunnerTimeoutAndCancellationCannotHangOnOpenPipes() async throws {
    let workspace = try StubWorkspace()
    let context = try runtimeContext()
    let short = try await workspace.resolver(mode: "wait", timeout: 0.15).resolve(runtimeExec())
    await #expect(throws: ProcessFailure.timedOut) {
        try await CredentialRunner().acquire(context: context, plugin: short, progress: { _ in })
    }
    let plugin = try await workspace.resolver(mode: "wait").resolve(runtimeExec())
    let capture = TextCapture()
    let task = Task { try await CredentialRunner().acquire(context: context, plugin: plugin, progress: capture.append) }
    defer { task.cancel(); workspace.release() }
    try await eventually { capture.value.contains("waiting without newline") }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func actualRunnerDoesNotWaitOnDescendantInheritedPipesAndCleansOwnedGroup() async throws {
    let workspace = try StubWorkspace()
    let plugin = try await workspace.resolver(mode: "inherited-pipe").resolve(runtimeExec())
    let capture = TextCapture()
    let result = try await CredentialRunner().acquire(context: runtimeContext(), plugin: plugin, progress: capture.append)
    #expect(result.token == "synthetic-credential-only")
    let child = try #require(Int32(capture.value))
    defer { if Darwin.kill(child, 0) == 0 { _ = Darwin.kill(child, SIGKILL) } }
    try await eventually { Darwin.kill(child, 0) != 0 }
}

@Test func incrementalUTF8RetainsOnlyIncompleteScalars() {
    var decoder = IncrementalUTF8()
    #expect(decoder.append(Data([0xE2])) == "")
    #expect(decoder.append(Data([0x82])) == "")
    #expect(decoder.append(Data([0xAC, 0x20, 0x41])) == "€ A")
    #expect(decoder.append(Data([0xF0, 0x9F])) == "")
    #expect(decoder.append(Data([0x98, 0x80])) == "😀")
    #expect(decoder.append(Data([0xFF])) == "�")
    #expect(decoder.append(Data([0xE2])) == "")
    #expect(decoder.finish() == "�")
    #expect(decoder.finish() == "")
}

@Test func actualProcessRunnerLaunchFailureIsSanitized() async {
    await #expect(throws: ProcessFailure.launchFailed) {
        try await ProcessRunner().run(ProcessRequest(
            executable: URL(fileURLWithPath: "/synthetic/nonexistent/plugin"),
            arguments: ["synthetic-secret"], environment: [:], timeout: 1
        ), progress: { _ in })
    }
}

@Test func actualProcessInstructionModeBoundsStdoutWhileStreaming() async throws {
    let workspace = try StubWorkspace()
    var environment = workspace.environment(mode: "overflow")
    environment["KUBERNETES_EXEC_INFO"] = #"{"spec":{"interactive":false}}"#
    let capture = TextCapture()
    let result = try await ProcessRunner().run(ProcessRequest(
        executable: workspace.executable, arguments: [], environment: environment, timeout: 5, output: .instructions
    ), progress: capture.append)
    #expect(result.exitCode == 0)
    #expect(result.stdout.count <= 8_192)
    #expect(capture.value.utf8.count > 1_048_576)
    var description = ""
    dump(ProcessResult(stdout: syntheticCredential, exitCode: 0), to: &description)
    #expect(!description.contains("synthetic-credential-only"))
}

@Test func actualProcessCancellationOfOneProviderWaiterLeavesOtherWaiterAlive() async throws {
    let workspace = try StubWorkspace()
    let provider = CredentialProvider(resolver: workspace.resolver(mode: "wait"))
    let context = try runtimeContext()
    let firstText = TextCapture()
    let secondText = TextCapture()
    let first = Task { try await provider.acquire(for: context, progress: firstText.append) }
    let second = Task { try await provider.acquire(for: context, progress: secondText.append) }
    defer { first.cancel(); second.cancel(); workspace.release() }
    try await eventually { firstText.value.contains("waiting") && secondText.value.contains("waiting") }
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    workspace.release()
    #expect(try await second.value.entry?.credential.token == "synthetic-credential-only")
}

@Test @MainActor func actualCredentialProcessLeavesMainActorResponsive() async throws {
    let workspace = try StubWorkspace()
    let plugin = try await workspace.resolver(mode: "wait").resolve(runtimeExec())
    let context = try runtimeContext()
    let capture = TextCapture()
    let task = Task { try await CredentialRunner().acquire(context: context, plugin: plugin, progress: capture.append) }
    defer { task.cancel(); workspace.release() }
    try await eventually { capture.value.contains("waiting without newline") }
    MainActor.preconditionIsolated()
    workspace.release()
    #expect(try await task.value.token == "synthetic-credential-only")
}

@Test(arguments: [
    ProcessRequest(executable: URL(fileURLWithPath: "/synthetic/tool"), arguments: [], environment: [:], timeout: 0),
    ProcessRequest(executable: URL(fileURLWithPath: "/synthetic/tool"), arguments: ["bad\0arg"], environment: [:], timeout: 1),
    ProcessRequest(executable: URL(fileURLWithPath: "/synthetic/tool"), arguments: [], environment: ["BAD=KEY": "value"], timeout: 1),
    ProcessRequest(executable: URL(fileURLWithPath: "/synthetic/tool"), arguments: [], environment: ["KEY": "bad\0value"], timeout: 1)
])
func processRejectsUnrepresentableRequestsBeforeLaunch(request: ProcessRequest) async {
    await #expect(throws: ProcessFailure.invalidRequest) { try await ProcessRunner().run(request, progress: { _ in }) }
}

@Test func credentialRunnerLoadsCAOnlyWhenRequestedAndSurfacesMaterialFailures() async throws {
    var configuration = Kubeconfig(
        currentContext: "context",
        clusters: [NamedCluster(name: "cluster", cluster: KubeconfigCluster(server: "https://synthetic.invalid", certificateAuthority: "/synthetic/ca"))],
        contexts: [NamedContext(name: "context", context: KubeconfigContext(cluster: "cluster", user: "user"))],
        users: [NamedUser(name: "user", user: KubeconfigUser(exec: runtimeExec()))]
    )
    configuration.users[0].user.exec?.provideClusterInfo = true
    let context = try configuration.resolve()
    let materials = MaterialFiles()
    let process = FakeProcess()
    let runner = CredentialRunner(process: process, materials: materials)
    let plugin = try await testResolver().resolve(try #require(context.user?.exec))
    await #expect(throws: AuthenticationError.materialUnavailable) {
        try await runner.acquire(context: context, plugin: plugin, progress: { _ in })
    }
    #expect(await process.requests().isEmpty)
    await materials.set("/synthetic/ca", Data("synthetic-ca".utf8))
    _ = try await runner.acquire(context: context, plugin: plugin, progress: { _ in })
    let requests = await process.requests()
    let info = try #require(requests.first?.environment["KUBERNETES_EXEC_INFO"])
    #expect(info.contains(Data("synthetic-ca".utf8).base64EncodedString()))
    let workspace = try StubWorkspace()
    let local = workspace.root.appendingPathComponent("token")
    try Data("synthetic-file".utf8).write(to: local)
    #expect(try await LocalAuthMaterialReader().read(local.path) == Data("synthetic-file".utf8))
    await #expect(throws: AuthenticationError.materialUnavailable) {
        try await LocalAuthMaterialReader().read(workspace.root.appendingPathComponent("absent").path)
    }
}
