import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Test func resolverUsesExplicitShimDirectoriesWithSparseFinderPath() async throws {
    let resolver = PluginResolver(
        environment: ["PATH": "/usr/bin:/bin"],
        store: MemoryAuthSettingsStore(AuthSettings(searchDirectories: ["/synthetic/mise/shims"])),
        shell: FixedShell(path: "/usr/bin:/bin"), files: Executables(paths: ["/synthetic/mise/shims/aws"])
    )
    let resolved = try await resolver.resolve(runtimeExec(command: "aws"))
    #expect(resolved.executable.path == "/synthetic/mise/shims/aws")
    #expect(resolved.environment["PATH"] == "/synthetic/mise/shims:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
    #expect(resolved.source == "effective PATH")
}

@Test func resolverEnvironmentPrecedenceAndNoImplicitCurrentDirectory() async throws {
    let resolver = testResolver(
        settings: AuthSettings(searchDirectories: ["/shims"]),
        environment: ["VALUE": "inherited", "KEEP": "yes"], files: Executables(paths: ["/exec/plugin", "/shims/plugin"])
    )
    let plugin = try await resolver.resolve(runtimeExec(env: [
        ExecEnvironmentVariable(name: "PATH", value: "/exec"),
        ExecEnvironmentVariable(name: "VALUE", value: "kubeconfig")
    ]))
    #expect(plugin.executable.path == "/shims/plugin")
    #expect(plugin.environment["VALUE"] == "kubeconfig")
    #expect(plugin.environment["KEEP"] == "yes")
    #expect(plugin.environment["PATH"] == "/shims:/exec:/opt/homebrew/bin:/usr/local/bin")
    let relativePath = runtimeExec(env: [ExecEnvironmentVariable(name: "PATH", value: ":relative:")])
    let empty = testResolver(files: Executables(paths: ["relative/plugin", "/plugin"]))
    await #expect(throws: PluginDiagnostic.self) { try await empty.resolve(relativePath) }
}

@Test func resolverAbsoluteOverridesAndRelativeCommandNeverSearchPath() async throws {
    let resolver = testResolver(
        settings: AuthSettings(executableOverrides: ["plugin": "/override/plugin"]),
        files: Executables(paths: ["/override/plugin", "/config/scripts/plugin", "/tools/scripts/plugin"])
    )
    let override = try await resolver.resolve(runtimeExec())
    #expect(override.executable.path == "/override/plugin")
    #expect(override.source == "absolute override")
    let relative = try await resolver.resolve(
        runtimeExec(command: "scripts/plugin"), sourceFile: URL(fileURLWithPath: "/config/kube.yaml")
    )
    #expect(relative.executable.path == "/config/scripts/plugin")
    #expect(relative.source == "kubeconfig-relative command")
    let absolute = try await resolver.resolve(runtimeExec(command: "/override/plugin"))
    #expect(absolute.source == "absolute kubeconfig command")
    await #expect(throws: PluginDiagnostic.self) { try await resolver.resolve(runtimeExec(command: "scripts/plugin")) }
}

@Test func resolverMissingExecutableExposesInstallHintAndPathActionWithoutDumpingEnvironment() async throws {
    var config = runtimeExec()
    config.installHint = "Install the synthetic plugin with the approved package manager"
    let resolver = testResolver(environment: ["SECRET": "synthetic-secret"], files: Executables(paths: []))
    do {
        _ = try await resolver.resolve(config)
        Issue.record("Expected a missing-plugin diagnostic")
    } catch let error as PluginDiagnostic {
        #expect(error.installHint == config.installHint)
        #expect(error.action == "Configure Plugin Path")
        // Standard install locations are part of the search, so the diagnostic must name them too.
        #expect(error.searchedPath == "/tools:/opt/homebrew/bin:/usr/local/bin")
        #expect(error.source == "effective PATH")
        #expect(!String(reflecting: error).contains("synthetic-secret"))
    }
}

actor CountingShell: ShellPathProviding {
    private(set) var count = 0
    func baseline(environment: [String: String]) -> ShellPathResult {
        count += 1
        return ShellPathResult(path: "/baseline\(count)")
    }
}

@Test func resolverSettingsChangesInvalidateBaselineAndPersistOnlySettings() async throws {
    let store = MemoryAuthSettingsStore()
    let shell = CountingShell()
    let resolver = PluginResolver(
        environment: [:], store: store, shell: shell,
        files: Executables(paths: ["/baseline1/plugin", "/new/plugin"])
    )
    let first = try await resolver.resolve(runtimeExec())
    _ = try await resolver.resolve(runtimeExec())
    #expect(await shell.count == 1)
    let settings = AuthSettings(executableOverrides: ["plugin": "/new/plugin"], timeout: 700)
    try await resolver.update(settings: settings)
    let changed = try await resolver.resolve(runtimeExec())
    #expect(await shell.count == 2)
    #expect(await store.load() == settings)
    #expect(first.executable != changed.executable)
    #expect(changed.environment["PATH"] == "/baseline2:/opt/homebrew/bin:/usr/local/bin")
}

@Test func shellPathUsesBoundedInteractiveLoginBaselineAndSurfacesFallback() async throws {
    let fake = FakeProcess { request, _ in
        // Interactive, because Homebrew/mise/asdf/rbenv live in .zshrc, which -lc never reads.
        #expect(request.arguments == ["-ilc", "printf '\\036%s\\037' \"$PATH\""])
        #expect(request.timeout == 10)
        return ProcessResult(stdout: Data("startup noise\u{1e}/baseline/bin\u{1f}".utf8), exitCode: 0)
    }
    let shell = ShellPath(runner: fake)
    let found = await shell.baseline(environment: ["SHELL": "/synthetic/zsh", "PATH": "/inherited"])
    #expect(found.path == "/baseline/bin")
    #expect(!found.usedFallback)
    let failure = FakeProcess { _, _ in throw ProcessFailure.timedOut }
    let fallback = await ShellPath(runner: failure).baseline(environment: ["SHELL": "/synthetic/zsh", "PATH": "/inherited"])
    #expect(fallback.path == "/inherited")
    #expect(fallback.usedFallback)
    #expect(fallback.diagnostic?.contains("Configure Plugin Path") == true)
    let missing = await shell.baseline(environment: ["SHELL": "relative"])
    #expect(missing.usedFallback)
    #expect(await fake.requests().count == 1)
}

@Test(arguments: [
    ProcessResult(stdout: Data("noise".utf8), exitCode: 0),
    ProcessResult(stdout: Data("\u{1e}/bad\npath\u{1f}".utf8), exitCode: 0),
    ProcessResult(stdout: Data("\u{1e}/path\u{1f}".utf8), exitCode: 2)
])
func shellPathRejectsUnusableOutput(result: ProcessResult) async {
    let shell = ShellPath(runner: FakeProcess { _, _ in result })
    let baseline = await shell.baseline(environment: ["SHELL": "/synthetic/sh", "PATH": "/inherited"])
    #expect(baseline.path == "/inherited")
    #expect(baseline.usedFallback)
}

@Test func localSettingsStoreRoundTripAndSanitizedFailures() async throws {
    let workspace = try StubWorkspace()
    let url = workspace.root.appendingPathComponent("settings.json")
    let store = FileAuthSettingsStore(url: url)
    #expect(try await store.load() == AuthSettings())
    let settings = AuthSettings(searchDirectories: ["/shims"], awsProfiles: ["user": AWSProfileBinding(profile: "dev")])
    try await store.save(settings)
    #expect(try await store.load() == settings)
    let contents = try Data(contentsOf: url)
    let keys = try #require(JSONSerialization.jsonObject(with: contents) as? [String: Any])
    #expect(Set(keys.keys) == ["searchDirectories", "executableOverrides", "awsProfiles", "timeout"])
    try Data("not valid settings".utf8).write(to: url)
    await #expect(throws: AuthenticationError.settingsUnavailable) { try await store.load() }
    let invalid = FileAuthSettingsStore(url: workspace.root.appendingPathComponent("absent/settings.json"))
    await #expect(throws: AuthenticationError.settingsUnavailable) { try await invalid.save(settings) }
    #expect(LocalPluginFileSystem().isExecutable(workspace.executable.path))
    #expect(!LocalPluginFileSystem().isExecutable(workspace.root.path))
    #expect(!LocalPluginFileSystem().isExecutable(url.path))
}

actor PausedShell: ShellPathProviding {
    let gate = TestGate()
    private(set) var calls = 0
    func baseline(environment: [String: String]) async -> ShellPathResult {
        calls += 1
        if calls == 1 { try? await gate.wait() }
        return ShellPathResult(path: "/old")
    }
}

@Test func settingsChangeDuringBaselineNeverReturnsStaleResolution() async throws {
    let shell = PausedShell()
    let resolver = PluginResolver(
        environment: [:], store: MemoryAuthSettingsStore(), shell: shell,
        files: Executables(paths: ["/old/plugin", "/new/plugin"])
    )
    let task = Task { try await resolver.resolve(runtimeExec()) }
    defer { task.cancel() }
    try await eventually { await shell.calls == 1 }
    try await resolver.update(settings: AuthSettings(executableOverrides: ["plugin": "/new/plugin"]))
    await shell.gate.open()
    #expect(try await task.value.executable.path == "/new/plugin")
    #expect(await shell.calls == 2)
}

@Test func invalidSettingsCannotChangePersistedOrEffectiveConfiguration() async throws {
    let store = MemoryAuthSettingsStore()
    let shell = CountingShell()
    let resolver = PluginResolver(environment: [:], store: store, shell: shell, files: Executables(paths: ["/baseline1/plugin"]))
    let first = try await resolver.resolve(runtimeExec())
    await #expect(throws: AuthenticationError.invalidSettings) { try await resolver.update(settings: AuthSettings(timeout: -1)) }
    let second = try await resolver.resolve(runtimeExec())
    #expect(second.executable == first.executable)
    #expect(await shell.count == 1)
    #expect(await store.load() == AuthSettings())
    await #expect(throws: AuthError.invalidExecCommand) { try await resolver.resolve(runtimeExec(command: "plugin\0suffix")) }
}

@Test func standardInstallDirectoriesAreSearchedLastSoAFinderLaunchStillResolves() async throws {
    let home = "/Users/synthetic"
    let directories = PluginResolver.standardDirectories(["HOME": home])
    #expect(directories == ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"])
    // A relative or absent HOME cannot contribute a search directory.
    #expect(PluginResolver.standardDirectories(["HOME": "relative/home"]).count == 2)
    #expect(PluginResolver.standardDirectories([:]).count == 2)
}

@Test func aPluginOnlyInAStandardDirectoryResolvesWhenDiscoveryFindsNothing() async throws {
    let resolver = PluginResolver(
        environment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/synthetic"],
        store: MemoryAuthSettingsStore(), shell: FixedShell(path: "/usr/bin:/bin"),
        files: Executables(paths: ["/opt/homebrew/bin/aws"])
    )
    let resolved = try await resolver.resolve(runtimeExec(command: "aws"))
    #expect(resolved.executable.path == "/opt/homebrew/bin/aws")
    #expect(resolved.source == "effective PATH")
    #expect(resolved.environment["PATH"]
        == "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:/Users/synthetic/.local/bin")
}

@Test func aDiscoveredPluginIsNeverShadowedByAStandardDirectory() async throws {
    let resolver = PluginResolver(
        environment: ["PATH": "/discovered/bin"], store: MemoryAuthSettingsStore(),
        shell: FixedShell(path: "/discovered/bin"),
        files: Executables(paths: ["/discovered/bin/aws", "/opt/homebrew/bin/aws"])
    )
    #expect(try await resolver.resolve(runtimeExec(command: "aws")).executable.path == "/discovered/bin/aws")
}
