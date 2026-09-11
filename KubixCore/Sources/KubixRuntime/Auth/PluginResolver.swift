import Foundation
import KubixCore

public struct PluginDiagnostic: Error, Sendable, LocalizedError, CustomStringConvertible, CustomReflectable, AuthenticationDiagnosticProviding {
    public let installHint: String?
    public let source: String
    public let searchedPath: String
    public let baselineDiagnostic: String?
    public var action: String { "Configure Plugin Path" }
    public var description: String { "Authentication plugin not found. Configure Plugin Path (details redacted)." }
    public var errorDescription: String? { description }
    public var authenticationDiagnostic: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["contents": "redacted"]) }
}

public struct ResolvedPlugin: Sendable, CustomStringConvertible, CustomReflectable {
    public let executable: URL
    public let environment: [String: String]
    public let settings: AuthSettings
    public let source: String
    public let baselineDiagnostic: String?
    public var description: String { "ResolvedPlugin (contents redacted)" }
    public var customMirror: Mirror { Mirror(self, children: ["contents": "redacted"]) }
}

public protocol PluginFileSystem: Sendable {
    func isExecutable(_ path: String) -> Bool
}

public struct LocalPluginFileSystem: PluginFileSystem {
    public init() {}
    public func isExecutable(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
}

public actor PluginResolver {
    private let environment: [String: String]
    private let shell: any ShellPathProviding
    private let files: any PluginFileSystem
    private let store: any AuthSettingsStoring
    private var cachedSettings: AuthSettings?
    private var cachedBaseline: SharedOperation<ShellPathResult>?
    private let owner = SharedOperationOwner<ShellPathResult>()
    private var revision = 0

    public init(
        environment: [String: String], store: any AuthSettingsStoring,
        shell: any ShellPathProviding = ShellPath(), files: any PluginFileSystem = LocalPluginFileSystem()
    ) {
        self.environment = environment
        self.store = store
        self.shell = shell
        self.files = files
    }

    public func settings() async throws -> AuthSettings {
        try owner.checkOpen()
        if let cachedSettings { return cachedSettings }
        let version = revision
        let loaded = try await store.load()
        try owner.checkOpen()
        try loaded.validate()
        if version != revision { return try await settings() }
        cachedSettings = loaded
        return loaded
    }

    public func update(settings: AuthSettings) async throws {
        try owner.checkOpen()
        try settings.validate()
        try await store.save(settings)
        try owner.checkOpen()
        revision += 1
        cachedSettings = settings
        cachedBaseline?.cancel()
        cachedBaseline = nil
    }

    public func resolve(
        _ configuration: KubeconfigExec, sourceFile: URL? = nil, userName: String? = nil
    ) async throws -> ResolvedPlugin {
        guard !configuration.command.isEmpty, !configuration.command.contains("\0") else { throw AuthError.invalidExecCommand }
        let settings = try await settings()
        let version = revision
        // Must keep throwing here: a shut-down owner cannot make the operation, and the force-unwrap
        // below would otherwise trap instead of surfacing the shutdown.
        try startBaseline()
        let baseline: ShellPathResult
        do { baseline = try await cachedBaseline!.value() } catch {
            try owner.checkOpen()
            if version != revision { return try await resolve(configuration, sourceFile: sourceFile, userName: userName) }
            throw error
        }
        try owner.checkOpen()
        if version != revision { return try await resolve(configuration, sourceFile: sourceFile, userName: userName) }
        var effective = environment
        effective["PATH"] = baseline.path
        for variable in configuration.env ?? [] { effective[variable.name] = variable.value }
        let path = (settings.searchDirectories + [effective["PATH"] ?? ""]
            + Self.standardDirectories(environment)).joined(separator: ":")
        effective["PATH"] = path
        if let userName, let binding = settings.awsProfiles[userName] {
            let invocation = try AWSInvocation(configuration: configuration)
            _ = try invocation.profile(environment: effective, binding: binding)
            effective["AWS_PROFILE"] = binding.profile
        }

        let selection = executable(configuration.command, settings: settings, path: path, sourceFile: sourceFile)
        guard let selected = selection.path, files.isExecutable(selected) else {
            throw PluginDiagnostic(
                installHint: configuration.installHint, source: selection.source, searchedPath: path,
                baselineDiagnostic: baseline.diagnostic
            )
        }
        return ResolvedPlugin(
            executable: URL(fileURLWithPath: selected), environment: effective, settings: settings,
            source: selection.source, baselineDiagnostic: baseline.diagnostic
        )
    }

    /// Starts the login-shell PATH probe without waiting for it. Composition calls this at launch so
    /// an interactive shell that takes seconds to load its version managers is read while the user is
    /// still looking at the sidebar, rather than inside the first Connect.
    public func warmBaseline() { try? startBaseline() }

    private func startBaseline() throws {
        guard cachedBaseline == nil || cachedBaseline?.isCancelled == true else { return }
        cachedBaseline = try owner.make { [shell, environment] _ in await shell.baseline(environment: environment) }
    }

    public func shutdown() async {
        await owner.shutdown()
        cachedBaseline = nil
    }

    /// Appended last, after the kubeconfig's own command, any configured override and the discovered
    /// PATH, so a deliberate choice always wins. They exist so a Finder launch still finds a normally
    /// installed plugin when shell discovery recovers nothing — a shell whose setup is TTY-guarded, or
    /// one whose flags this probe does not speak.
    static func standardDirectories(_ environment: [String: String]) -> [String] {
        let home = environment["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        return ["/opt/homebrew/bin", "/usr/local/bin"] + (home.map { ["\($0)/.local/bin"] } ?? [])
    }

    private func executable(
        _ command: String, settings: AuthSettings, path: String, sourceFile: URL?
    ) -> (path: String?, source: String) {
        if let override = settings.executableOverrides[command] { return (override, "absolute override") }
        if command.hasPrefix("/") { return (command, "absolute kubeconfig command") }
        if command.contains("/") {
            let resolved = sourceFile?.deletingLastPathComponent().appendingPathComponent(command).standardizedFileURL.path
            return (resolved, "kubeconfig-relative command")
        }
        // Ignore empty/relative PATH entries: Finder's cwd must never select an unintended binary.
        let candidates = path.split(separator: ":").filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: String($0)).appendingPathComponent(command).path
        }
        return (candidates.first(where: files.isExecutable), "effective PATH")
    }
}
