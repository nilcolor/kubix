import Darwin
import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

let syntheticCredential = Data("""
{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"token":"synthetic-credential-only"}}
""".utf8)

func runtimeContext(
    user: KubeconfigUser? = KubeconfigUser(exec: runtimeExec()), name: String = "context",
    userName: String = "user", server: String = "https://synthetic.invalid"
) throws -> ResolvedContext {
    try Kubeconfig(
        currentContext: name, clusters: [NamedCluster(name: "cluster", cluster: KubeconfigCluster(server: server))],
        contexts: [NamedContext(name: name, context: KubeconfigContext(cluster: "cluster", user: user == nil ? nil : userName))],
        users: user.map { [NamedUser(name: userName, user: $0)] } ?? []
    ).resolve()
}

func runtimeExec(
    command: String = "plugin", args: [String] = [], env: [ExecEnvironmentVariable] = [],
    mode: String = "Never"
) -> KubeconfigExec {
    KubeconfigExec(command: command, apiVersion: "client.authentication.k8s.io/v1", args: args, env: env, interactiveMode: mode)
}

func awsContext(profile: String = "dev", server: String = "https://synthetic.invalid") throws -> ResolvedContext {
    try runtimeContext(
        user: KubeconfigUser(exec: runtimeExec(command: "aws", args: ["eks", "get-token", "--cluster-name", "synthetic", "--profile", profile])),
        server: server
    )
}

struct FixedShell: ShellPathProviding {
    let path: String
    func baseline(environment: [String: String]) -> ShellPathResult { ShellPathResult(path: path) }
}

struct Executables: PluginFileSystem {
    var paths: Set<String> = ["/tools/plugin", "/tools/aws"]
    func isExecutable(_ path: String) -> Bool { paths.contains(path) }
}

func testResolver(
    settings: AuthSettings = AuthSettings(), environment: [String: String] = [:],
    files: any PluginFileSystem = Executables()
) -> PluginResolver {
    PluginResolver(environment: environment, store: MemoryAuthSettingsStore(settings), shell: FixedShell(path: "/tools"), files: files)
}

actor FakeProcess: ProcessRunning {
    typealias Handler = @Sendable (ProcessRequest, @escaping AuthProgress) async throws -> ProcessResult
    private var calls: [ProcessRequest] = []
    private let handler: Handler
    init(handler: @escaping Handler = { _, _ in ProcessResult(stdout: syntheticCredential, exitCode: 0) }) {
        self.handler = handler
    }
    func run(_ request: ProcessRequest, progress: @escaping AuthProgress) async throws -> ProcessResult {
        calls.append(request)
        return try await handler(request, progress)
    }
    func requests() -> [ProcessRequest] { calls }
}

actor MaterialFiles: AuthMaterialReading {
    var files: [String: Data]
    private(set) var reads: [String] = []
    init(_ files: [String: Data] = [:]) { self.files = files }
    func set(_ path: String, _ data: Data?) { files[path] = data }
    func read(_ path: String) throws -> Data {
        reads.append(path)
        guard let bytes = files[path] else { throw AuthenticationError.materialUnavailable }
        return bytes
    }
}

actor TestGate {
    private var opened = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
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
        for continuation in pending { continuation.resume() }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}

enum TestFailure: Error { case deadline, missingFixture }

func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw TestFailure.deadline }
        try await Task.sleep(for: .milliseconds(1))
    }
}

final class TextCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    var value: String { lock.withLock { text } }
    func append(_ value: String) { lock.withLock { text += value } }
}

/// Unique repository-local resources only; no user shell files, credentials, or system temp paths.
final class StubWorkspace: @unchecked Sendable {
    let root: URL
    let executable: URL
    let gate: URL
    private let gateFD: Int32

    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = package.appendingPathComponent(".build/auth-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appendingPathComponent("aws")
        guard let fixture = Bundle.module.url(forResource: "exec-stub", withExtension: "sh", subdirectory: "Fixtures") else {
            throw TestFailure.missingFixture
        }
        // Reuse the immutable packaged executable; unique copied scripts serialize first-launch
        // validation on macOS and can exhaust otherwise unrelated five-second auth deadlines.
        guard FileManager.default.isExecutableFile(atPath: fixture.path) else { throw TestFailure.missingFixture }
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: fixture)
        gate = root.appendingPathComponent("gate")
        guard mkfifo(gate.path, 0o600) == 0 else { throw TestFailure.missingFixture }
        gateFD = Darwin.open(gate.path, O_RDWR | O_NONBLOCK)
        guard gateFD >= 0 else { throw TestFailure.missingFixture }
    }

    func release() {
        let bytes: [UInt8] = [103, 111, 10]
        _ = bytes.withUnsafeBytes { Darwin.write(gateFD, $0.baseAddress, $0.count) }
    }

    func environment(mode: String) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "STUB_MODE": mode, "STUB_GATE": gate.path]
    }

    func resolver(mode: String, timeout: TimeInterval = 5) -> PluginResolver {
        PluginResolver(
            environment: environment(mode: mode),
            store: MemoryAuthSettingsStore(AuthSettings(executableOverrides: ["plugin": executable.path, "aws": executable.path], timeout: timeout)),
            shell: FixedShell(path: "/usr/bin:/bin")
        )
    }

    deinit {
        Darwin.close(gateFD)
        try? FileManager.default.removeItem(at: root)
    }
}
