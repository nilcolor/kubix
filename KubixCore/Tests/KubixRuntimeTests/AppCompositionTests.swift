import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

private struct ConfigurationFiles: KubeconfigFileSystem {
    let bytes: Data?
    func readFile(at url: URL) -> Data? { bytes }
}

@Test func appLoaderSurfacesMissingAndMalformedInjectedFilesWithoutHostAccess() async {
    for bytes in [Data?.none, Data("contexts: [broken".utf8)] {
        let loader = AppConfigurationLoader(
            loader: KubeconfigLoader(
                environment: ["KUBECONFIG": "/synthetic/config"],
                homeDirectory: URL(fileURLWithPath: "/synthetic"),
                workingDirectory: URL(fileURLWithPath: "/synthetic"), fileSystem: ConfigurationFiles(bytes: bytes)
            ), settings: MemoryAuthSettingsStore()
        )
        let snapshot = await loader.load()
        #expect(snapshot.contexts.isEmpty && snapshot.diagnostics.count == 1)
        #expect(!snapshot.diagnostics.joined().contains("[broken"))
    }
}

private actor RegistryFactory {
    let gate = TestGate()
    var calls = 0
    var fail = false
    func make(_ context: ResolvedContext) async throws -> any Transport {
        calls += 1
        try await gate.wait()
        if fail { throw APIError.transport(.connection) }
        return ExecTestTransport(ExecTestSocket())
    }
    func setFailure(_ value: Bool) { fail = value }
}

@Test func registryCoalescesSameSnapshotButDoesNotReuseSameNameWithChangedServer() async throws {
    let factory = RegistryFactory()
    let registry = ContextTransportRegistry(factory: { try await factory.make($0) })
    let context = try runtimeContext(user: nil)
    let first = Task { try await registry.transport(for: context) }
    let second = Task { try await registry.transport(for: context) }
    try await eventually { await factory.calls == 1 }
    await factory.gate.open()
    let a = try await first.value
    let b = try await second.value
    let same = (a as AnyObject) === (b as AnyObject)
    #expect(same)
    _ = try await registry.transport(for: runtimeContext(user: nil, server: "https://other.synthetic.invalid"))
    #expect(await factory.calls == 2)
    await registry.shutdown()
}

@Test func failedRegistryCreationCanRetry() async throws {
    let factory = RegistryFactory()
    await factory.gate.open()
    await factory.setFailure(true)
    let registry = ContextTransportRegistry(factory: { try await factory.make($0) })
    let context = try runtimeContext(user: nil)
    await #expect(throws: APIError.transport(.connection)) { try await registry.transport(for: context) }
    await factory.setFailure(false)
    _ = try await registry.transport(for: context)
    #expect(await factory.calls == 2)
    await registry.shutdown()
}

@Test func pluginPresentationUsesSameResolvedOverrideAndProfileWithoutRunningAProcess() async throws {
    let process = FakeProcess()
    let resolver = testResolver(
        settings: AuthSettings(executableOverrides: ["aws": "/stable/aws"]),
        files: Executables(paths: ["/stable/aws"])
    )
    let (auth, _) = orchestration(process: process, resolver: resolver)
    let presentation = await auth.presentation(for: try awsContext())
    #expect(presentation.executable == "/stable/aws")
    #expect(presentation.source == "absolute override")
    #expect(presentation.profile == "dev" && presentation.canSignIn)
    #expect(await process.requests().isEmpty)
    try await auth.update(settings: AuthSettings(
        executableOverrides: ["aws": "/stable/aws"], awsProfiles: ["user": AWSProfileBinding(profile: "conflict")]
    ))
    let conflict = await auth.presentation(for: try awsContext())
    #expect(!conflict.canSignIn && conflict.diagnostic == AuthenticationError.conflictingAWSProfile.errorDescription)
}

@Test func appPresentationReportsMissingExecutableWithConfigureAction() async throws {
    let (auth, _) = orchestration(process: FakeProcess(), resolver: testResolver(files: Executables(paths: [])))
    let presentation = await auth.presentation(for: try awsContext())
    #expect(!presentation.canSignIn)
    #expect(presentation.diagnostic?.contains("Configure Plugin Path") == true)
}

@Test func awsVaultContextCannotSilentlySubstituteDirectAWSLogin() async throws {
    let process = FakeProcess()
    let resolver = testResolver(files: Executables(paths: ["/tools/aws-vault", "/tools/aws"]))
    let (auth, _) = orchestration(process: process, resolver: resolver)
    let context = try runtimeContext(user: KubeconfigUser(exec: runtimeExec(command: "aws-vault", args: [
        "exec", "synthetic-role", "--duration=1h", "--", "aws", "--region", "eu-synthetic-1",
        "eks", "get-token", "--cluster-name", "synthetic"
    ])))
    let presentation = await auth.presentation(for: context)
    #expect(presentation.executable == "/tools/aws-vault")
    #expect(!presentation.canSignIn && presentation.profile == nil)
    #expect(presentation.diagnostic == nil)
    await #expect(throws: AuthenticationError.unsupportedAWSInvocation) { try await auth.signIn(for: context) }
    #expect(await process.requests().isEmpty)
}

@Test func configuredWrapperAcquisitionPreservesCommandAndHidesCredentialOutput() async throws {
    let arguments = ["exec", "synthetic-role", "--", "aws", "eks", "get-token", "--cluster-name", "synthetic"]
    let process = FakeProcess { request, progress in
        #expect(request.executable.path == "/tools/aws-vault")
        #expect(request.arguments == arguments)
        #expect(request.output == .credential)
        #expect(request.environment["KUBERNETES_EXEC_INFO"] != nil)
        progress("Open https://synthetic.invalid/authorization")
        return ProcessResult(stdout: syntheticCredential, exitCode: 0)
    }
    let resolver = testResolver(files: Executables(paths: ["/tools/aws-vault"]))
    let (auth, _) = orchestration(process: process, resolver: resolver)
    let context = try runtimeContext(user: KubeconfigUser(exec: runtimeExec(command: "aws-vault", args: arguments)))
    let capture = SessionCapture()
    let observer = observe(auth, in: capture)
    defer { observer.cancel() }
    let acquired = try await auth.acquire(for: context)
    #expect(acquired.entry?.credential.token == "synthetic-credential-only")
    #expect(await process.requests().count == 1)
    try await eventually { capture.values.contains { $0.state == .succeeded } }
    #expect(capture.values.allSatisfy { !$0.instructions.contains("synthetic-credential-only") })
    #expect(capture.values.last?.instructions.isEmpty == true)
}

@Test func bridgeQuotedCommandIsParsedByAnActualNoninteractiveShell() async throws {
    let workspace = try StubWorkspace()
    let executable = workspace.root.appendingPathComponent("Kubix 'quoted' \"$HOME\".sh")
    try Data("#!/bin/sh\nprintf '%s\\n' \"$#\" \"$1\" \"$KUBIX_BRIDGE_SOCK\"\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let endpoint = try ExecBridgeEndpoint(
        socketPath: "/synthetic/session.sock", nonce: BridgeNonce(bytes: Data(repeating: 9, count: 32))
    )
    let configuration = try TerminalConfiguration.bridge(executablePath: executable.path, endpoint: endpoint)
    let request = ProcessRequest(
        executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", configuration.command!],
        environment: endpoint.environment, timeout: 5
    )
    let result = try await ProcessRunner().run(request, progress: { _ in })
    #expect(result.exitCode == 0)
    #expect(String(decoding: result.stdout, as: UTF8.self) == "1\n--pty-bridge\n/synthetic/session.sock\n")
}

@MainActor private final class PresentationBrowser: BrowserOpening {
    var opens = 0
    func open(_ url: URL) -> Bool { opens += 1; return true }
}

@MainActor private struct UnusedSurfaces: TerminalSurfaceCreating {
    func makeSurface(
        sessionID: UUID, target: ExecTarget, endpoint: ExecBridgeEndpoint,
        onChildExit: @escaping @MainActor @Sendable () -> Void
    ) throws -> any TerminalSurface { throw TestFailure.missingFixture }
}

private actor PresentationExec: ExecSessionControlling {
    var targets: [ExecTarget] = []
    func run(
        sessionID: UUID, target: ExecTarget,
        ready: @escaping @MainActor @Sendable (ExecBridgeEndpoint) throws -> Void,
        update: @escaping @MainActor @Sendable (ExecSession.State) -> Void
    ) -> ExecSessionResult {
        targets.append(target)
        return .exited(code: 0)
    }
    func childTerminated(sessionID: UUID) {}
}

@Test @MainActor func wrapperBrowserFailureWaitsForExplicitRetryOfOriginalCommandWithoutShells() async throws {
    let arguments = ["exec", "synthetic-role", "--", "aws", "eks", "get-token", "--cluster-name", "synthetic"]
    let gate = TestGate()
    let invocations = InvocationCount()
    let process = FakeProcess { request, progress in
        #expect(request.executable.path == "/tools/aws-vault" && request.arguments == arguments)
        #expect(request.environment["CONFIGURED_VALUE"] == "synthetic")
        #expect(request.output == .credential)
        if await invocations.next() == 1 {
            progress("Complete browser approval https://synthetic.invalid/authorize")
            try await gate.wait()
            return ProcessResult(stdout: Data(), exitCode: 17)
        }
        return ProcessResult(stdout: syntheticCredential, exitCode: 0)
    }
    let resolver = testResolver(files: Executables(paths: ["/tools/aws-vault"]))
    let (auth, _) = orchestration(process: process, resolver: resolver)
    let context = try runtimeContext(user: KubeconfigUser(exec: runtimeExec(
        command: "aws-vault", args: arguments, env: [.init(name: "CONFIGURED_VALUE", value: "synthetic")]
    )))
    let other = try runtimeContext(user: nil, name: "other")
    let store = AppStore(contexts: [context, other])
    let browser = PresentationBrowser()
    let exec = PresentationExec()
    let actions = AppActions(store: store, exec: exec, authentication: auth, surfaces: UnusedSurfaces(), browser: browser)
    defer { actions.shutdown() }
    try actions.selectContext(named: context.name)
    #expect(await auth.presentation(for: context).canSignIn == false)
    let first = Task { await actions.authenticateSelectedContext() }
    defer { first.cancel() }
    try await eventually { await MainActor.run { store.authenticationSessions.values.contains { !$0.instructions.isEmpty } } }
    let session = try #require(store.authenticationSessions.values.first)
    #expect(AuthPresentation(session).canCancel && browser.opens == 0)
    await actions.openAuthorizationURL(operationID: session.id)
    #expect(browser.opens == 1)
    await gate.open()
    await first.value
    try await eventually { await MainActor.run { store.authenticationSessions[session.id]?.state == .failed } }
    let failed = AuthPresentation(try #require(store.authenticationSessions[session.id]))
    #expect(failed.canRetry && failed.instructions.isEmpty)
    #expect(await process.requests().count == 1)
    try actions.selectContext(named: other.name)
    try await actions.retryAuthentication(operationID: session.id)
    try await eventually { await MainActor.run { store.authenticationSessions.values.contains { $0.state == .succeeded } } }
    #expect(await process.requests().count == 2)
    #expect(store.authenticationDiagnostic == nil && store.execSessions.isEmpty)
    #expect(store.authenticationSessions.values.allSatisfy { $0.instructions.isEmpty })
    #expect(await exec.targets.isEmpty && browser.opens == 1)
}

@Test @MainActor func productionAuthPresentationShowsLiveInstructionsNeverCredentialStdoutAndCoalescesShells() async throws {
    let gate = TestGate()
    let process = FakeProcess { request, progress in
        if request.arguments == ["--version"] {
            return ProcessResult(stdout: Data("aws-cli/2.99".utf8), exitCode: 0)
        }
        if request.arguments.first == "sso" {
            progress("Open https://synthetic.invalid/login SYNTHETIC-DEVICE")
            try await gate.wait()
            return ProcessResult(stdout: Data(), exitCode: 0)
        }
        return ProcessResult(stdout: syntheticCredential, exitCode: 0)
    }
    let (authentication, _) = orchestration(process: process)
    let context = try awsContext()
    let browser = PresentationBrowser()
    let store = AppStore(contexts: [context])
    let exec = PresentationExec()
    let actions = AppActions(
        store: store, exec: exec, authentication: authentication, surfaces: UnusedSurfaces(), browser: browser
    )
    defer { actions.shutdown() }
    let login = Task { try await actions.signIn(context: context, useDeviceCode: true) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !store.authenticationSessions.values.contains(where: { !$0.instructions.isEmpty }) {
        guard ContinuousClock.now < deadline else { throw TestFailure.deadline }
        try await Task.sleep(for: .milliseconds(1))
    }
    let session = try #require(store.authenticationSessions.values.first(where: { !$0.instructions.isEmpty }))
    let presentation = AuthPresentation(session)
    #expect(presentation.canCancel && presentation.instructions.contains("SYNTHETIC-DEVICE"))
    #expect(!presentation.instructions.contains("synthetic-credential-only"))
    #expect(browser.opens == 0)
    await actions.openAuthorizationURL(operationID: session.id)
    #expect(browser.opens == 1)
    let target = try ExecTarget(context: context, namespace: "synthetic", pod: "pod", container: "regular")
    actions.openShell(target: target)
    actions.openShell(target: target)
    #expect(await exec.targets.isEmpty)
    await gate.open()
    try await login.value
    try await eventually { await exec.targets.count == 2 }
    let requests = await process.requests()
    #expect(requests.filter { $0.arguments.contains("get-token") }.count == 1)
    #expect(requests.filter { $0.arguments.first == "sso" }.count == 1)
    #expect(requests.contains { $0.arguments.contains("--use-device-code") })
    #expect(store.authenticationSessions.values.allSatisfy { $0.instructions.isEmpty })
}
