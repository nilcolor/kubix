import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

func loginBinding(
    context: ResolvedContext? = nil, resolver: PluginResolver = testResolver()
) async throws -> AWSLoginBinding {
    let context = try context ?? awsContext()
    let config = try #require(context.user?.exec)
    let plugin = try await resolver.resolve(config, userName: context.userName)
    return try AWSLoginBinding(context: context, plugin: plugin)
}

@Test func awsProfileAndConfigBindingMatchesOriginalGetToken() async throws {
    let context = try runtimeContext(user: KubeconfigUser(exec: runtimeExec(command: "aws", args: [
        "--profile=dev", "--region", "eu-synthetic-1", "eks", "get-token", "--cluster-name", "synthetic"
    ], env: [
        ExecEnvironmentVariable(name: "AWS_CONFIG_FILE", value: "/synthetic/config"),
        ExecEnvironmentVariable(name: "AWS_SHARED_CREDENTIALS_FILE", value: "/synthetic/credentials")
    ])))
    let resolver = testResolver(
        settings: AuthSettings(awsProfiles: ["user": AWSProfileBinding(profile: "dev", session: "company")]),
        environment: ["AWS_PROFILE": "dev", "AWS_CONFIG_FILE": "/inherited/config", "KUBERNETES_EXEC_INFO": "not-for-login"]
    )
    let plugin = try await resolver.resolve(try #require(context.user?.exec), userName: context.userName)
    let binding = try AWSLoginBinding(context: context, plugin: plugin)
    #expect(binding.executable == plugin.executable)
    #expect(binding.profile == "dev")
    #expect(binding.session == "company")
    #expect(binding.environment["AWS_CONFIG_FILE"] == plugin.environment["AWS_CONFIG_FILE"])
    #expect(binding.environment["AWS_SHARED_CREDENTIALS_FILE"] == plugin.environment["AWS_SHARED_CREDENTIALS_FILE"])
    #expect(binding.environment["KUBERNETES_EXEC_INFO"] == nil)
    #expect(binding.options == ["--region", "eu-synthetic-1"])
}

@Test func awsExplicitSettingSuppliesProfileToGetTokenAndLogin() async throws {
    let context = try runtimeContext(user: KubeconfigUser(exec: runtimeExec(command: "aws", args: ["eks", "get-token"])))
    let resolver = testResolver(settings: AuthSettings(awsProfiles: ["user": AWSProfileBinding(profile: "configured")]))
    let plugin = try await resolver.resolve(try #require(context.user?.exec), userName: context.userName)
    let binding = try AWSLoginBinding(context: context, plugin: plugin)
    #expect(plugin.environment["AWS_PROFILE"] == "configured")
    #expect(binding.profile == "configured")
}

@Test(arguments: [
    ["AWS_PROFILE": "other"], ["AWS_DEFAULT_PROFILE": "other"],
    ["AWS_PROFILE": "dev", "AWS_DEFAULT_PROFILE": "other"]
])
func awsRejectsConflictingProfiles(environment: [String: String]) async throws {
    await #expect(throws: AuthenticationError.conflictingAWSProfile) {
        try await loginBinding(resolver: testResolver(environment: environment))
    }
}

@Test func awsRejectsConflictingAppSettingAndDuplicateArgument() async throws {
    let settings = AuthSettings(awsProfiles: ["user": AWSProfileBinding(profile: "other")])
    await #expect(throws: AuthenticationError.conflictingAWSProfile) {
        try await loginBinding(resolver: testResolver(settings: settings))
    }
    let context = try runtimeContext(user: KubeconfigUser(exec: runtimeExec(
        command: "aws", args: ["eks", "get-token", "--profile", "dev", "--profile=other"]
    )))
    await #expect(throws: AuthenticationError.conflictingAWSProfile) { try await loginBinding(context: context) }
}

@Test(arguments: [
    runtimeExec(command: "wrapper", args: ["aws", "eks", "get-token", "--profile", "dev"]),
    runtimeExec(command: "aws", args: ["sso", "login", "--profile", "dev"]),
    runtimeExec(command: "aws", args: ["eks", "get-token", "--unknown", "value"]),
    runtimeExec(command: "aws", args: ["eks", "get-token", "--profile"]),
    runtimeExec(command: "aws", args: ["eks", "get-token", "--debug"])
])
func awsNeverInventsWrapperOrUnknownRecoveryCommands(config: KubeconfigExec) throws {
    #expect(throws: AuthenticationError.unsupportedAWSInvocation) { try AWSInvocation(configuration: config) }
}

@Test func awsDoesNotGuessProfileFromContextNameAndReportsMissingCLI() async throws {
    let context = try runtimeContext(
        user: KubeconfigUser(exec: runtimeExec(command: "aws", args: ["eks", "get-token"])), name: "dev-profile"
    )
    await #expect(throws: AuthenticationError.missingAWSProfile) { try await loginBinding(context: context) }
    await #expect(throws: PluginDiagnostic.self) {
        try await loginBinding(resolver: testResolver(files: Executables(paths: [])))
    }
}

@Test(arguments: [false, true])
func awsLoginUsesSeparateCommandV2AndOptionalDeviceCode(deviceCode: Bool) async throws {
    let binding = try await loginBinding()
    let capture = TextCapture()
    let process = FakeProcess { request, progress in
        if request.arguments == ["--version"] {
            return ProcessResult(stdout: Data("aws-cli/2.99.0 synthetic".utf8), exitCode: 0)
        }
        #expect(request.output == .instructions)
        #expect(request.environment["AWS_PROFILE"] == "dev")
        #expect(request.environment["AWS_PAGER"] == "")
        #expect(request.environment["AWS_CLI_AUTO_PROMPT"] == "off")
        #expect(request.arguments.prefix(6) == ["sso", "login", "--profile", "dev", "--no-cli-pager", "--no-cli-auto-prompt"])
        #expect(request.arguments.contains("--use-device-code") == deviceCode)
        #expect(!request.arguments.contains("--no-browser"))
        #expect(request.timeout > 590 && request.timeout <= 600)
        progress("https://synthetic.invalid/pkce?code=synthetic\nDevice code SYNTHETIC")
        return ProcessResult(stdout: Data("login text is not ExecCredential JSON".utf8), exitCode: 0)
    }
    try await AWSLoginService(runner: process).login(binding, useDeviceCode: deviceCode, progress: capture.append)
    #expect(capture.value.contains("pkce"))
    #expect(await process.requests().count == 2)
}

@Test(arguments: [
    ProcessResult(stdout: Data("aws-cli/1.99.0".utf8), exitCode: 0),
    ProcessResult(stdout: Data("unknown executable".utf8), exitCode: 0),
    ProcessResult(stdout: Data("aws-cli/2.99.0".utf8), exitCode: 4)
])
func awsRejectsNonV2CLIWithoutStartingLogin(version: ProcessResult) async throws {
    let binding = try await loginBinding()
    let process = FakeProcess { _, _ in version }
    await #expect(throws: AuthenticationError.requiresAWSCLIV2) {
        try await AWSLoginService(runner: process).login(binding)
    }
    #expect(await process.requests().count == 1)
}

@Test func actualAWSStubStreamsBothChannelsBeforeEOFAndDeviceCodeLoginSucceeds() async throws {
    let workspace = try StubWorkspace()
    let binding = try await loginBinding(resolver: workspace.resolver(mode: "login-wait"))
    let capture = TextCapture()
    let login = AWSLoginService()
    let task = Task { try await login.login(binding, useDeviceCode: true, progress: capture.append) }
    defer { task.cancel(); workspace.release() }
    try await eventually { capture.value.contains("synthetic-login") && capture.value.contains("SYNTHETIC-CODE") }
    workspace.release()
    try await task.value
    #expect(!capture.value.contains("synthetic-credential-only"))
}

@Test func actualAWSStubTimeoutNonzeroAndCancellation() async throws {
    let workspace = try StubWorkspace()
    let timeout = try await loginBinding(resolver: workspace.resolver(mode: "login-wait", timeout: 0.15))
    await #expect(throws: ProcessFailure.timedOut) { try await AWSLoginService().login(timeout) }
    let nonzero = try await loginBinding(resolver: workspace.resolver(mode: "login-fail"))
    await #expect(throws: ProcessFailure.exited(23)) { try await AWSLoginService().login(nonzero) }
    let binding = try await loginBinding(resolver: workspace.resolver(mode: "login-wait"))
    let login = AWSLoginService()
    let capture = TextCapture()
    let task = Task { try await login.login(binding, progress: capture.append) }
    defer { task.cancel(); workspace.release() }
    try await eventually { capture.value.contains("SYNTHETIC-CODE") }
    await login.cancel(binding)
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func awsCoalescesProfileLoginAndIsolatesWaiterCancellation() async throws {
    let gate = TestGate()
    let process = FakeProcess { request, progress in
        if request.arguments == ["--version"] {
            return ProcessResult(stdout: Data("aws-cli/2.99".utf8), exitCode: 0)
        }
        progress("waiting")
        try await gate.wait()
        return ProcessResult(stdout: Data(), exitCode: 0)
    }
    let login = AWSLoginService(runner: process)
    let binding = try await loginBinding()
    let firstText = TextCapture()
    let secondText = TextCapture()
    let first = Task { try await login.login(binding, progress: firstText.append) }
    let second = Task { try await login.login(binding, progress: secondText.append) }
    defer { first.cancel(); second.cancel() }
    try await eventually { firstText.value == "waiting" && secondText.value == "waiting" }
    #expect(await process.requests().count == 2)
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    await gate.open()
    try await second.value
    #expect(await process.requests().count == 2)
}

@Test func awsSharesResolvedSSOSessionButSeparatesConfigEnvironment() async throws {
    let first = try await loginBinding(resolver: testResolver(
        settings: AuthSettings(awsProfiles: ["user": AWSProfileBinding(profile: "dev", session: "company")])
    ))
    let second = try await loginBinding(context: awsContext(profile: "prod"), resolver: testResolver(
        settings: AuthSettings(awsProfiles: ["user": AWSProfileBinding(profile: "prod", session: "company")])
    ))
    #expect(first.key == second.key)
    let differentConfig = try await loginBinding(resolver: testResolver(
        settings: AuthSettings(awsProfiles: ["user": AWSProfileBinding(profile: "dev", session: "company")]),
        environment: ["AWS_CONFIG_FILE": "/different/config"]
    ))
    #expect(first.key != differentConfig.key)
    let login = AWSLoginService(runner: FakeProcess())
    let operation = await login.operation(for: first, useDeviceCode: false)
    let shared = await login.operation(for: second, useDeviceCode: false)
    #expect(operation.id == shared.id)
    await login.cancel(first)
}
