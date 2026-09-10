#if DEBUG
import Darwin
import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

private let isolatedArguments = ["exec", "synthetic", "--duration=1h", "--", "aws", "--region", "eu-synthetic-1", "eks", "get-token"]

@Test func isolatedVaultPreservesArgvConfigAndOutputButUsesOnlyEncryptedOwnedBackend() async throws {
    let workspace = try StubWorkspace()
    let process = FakeProcess { request, _ in
        #expect(request.arguments == isolatedArguments && request.executable.path == "/tools/aws-vault")
        #expect(request.environment["AWS_CONFIG_FILE"] == "/synthetic/original-config")
        #expect(request.environment["AWS_VAULT_BACKEND"] == "file")
        #expect(request.environment["AWS_VAULT_FILE_PASSPHRASE"]?.count == 44)
        #expect(request.environment["AWS_VAULT_STDOUT"] == "true")
        #expect(request.environment["AWS_VAULT_PROFILE_ENV"] == "false")
        return ProcessResult(stdout: syntheticCredential, exitCode: 0)
    }
    let vault = IsolatedAWSVaultRunner(parent: workspace.root, profile: "synthetic", process: process)
    let initial = try await vault.prepare()
    #expect(initial.entries == 0 && initial.securePermissions)
    #expect(try bridgeFileMode(vault.directory.path) == 0o700)
    let result = try await vault.run(ProcessRequest(
        executable: URL(fileURLWithPath: "/tools/aws-vault"), arguments: isolatedArguments,
        environment: ["AWS_CONFIG_FILE": "/synthetic/original-config", "AWS_VAULT_PROFILE_ENV": "true"], timeout: 5
    ), progress: { _ in })
    #expect(result.stdout == syntheticCredential)
    #expect(await vault.calls == 1)
    var reflected = ""
    dump(vault, to: &reflected)
    #expect(!reflected.contains("PASSPHRASE") && !reflected.contains("passphrase"))
    try await vault.cleanup()
    #expect(!bridgeFileExists(vault.directory.path))
}

@Test(arguments: [
    ["exec", "synthetic", "--backend=keychain", "--", "aws", "eks", "get-token"],
    ["exec", "synthetic", "--profile-env", "--", "aws", "eks", "get-token"],
    ["exec", "synthetic", "--", "aws", "--profile", "other", "eks", "get-token"],
    ["exec", "synthetic", "--", "aws", "eks", "delete-cluster"],
    ["exec", "synthetic", "aws", "eks", "get-token", "--"],
])
func isolatedVaultRejectsBackendOverridesCacheSyncAndNonCredentialCommands(_ arguments: [String]) async throws {
    let workspace = try StubWorkspace()
    let process = FakeProcess()
    let vault = IsolatedAWSVaultRunner(parent: workspace.root, profile: "synthetic", process: process)
    await #expect(throws: IsolatedAWSVaultRunner.Failure.unsafeInvocation) {
        try await vault.run(ProcessRequest(
            executable: URL(fileURLWithPath: "/tools/aws-vault"), arguments: arguments, environment: [:], timeout: 5
        ), progress: { _ in })
    }
    #expect(await process.requests().isEmpty && !bridgeFileExists(vault.directory.path))
}

@Test func isolatedVaultChecksEnvelopeMetadataAndCleansOnlyItsOwnedFiles() async throws {
    let workspace = try StubWorkspace()
    let vault = IsolatedAWSVaultRunner(parent: workspace.root, profile: "synthetic", process: FakeProcess())
    _ = try await vault.prepare()
    let file = vault.directory.appendingPathComponent("synthetic-envelope")
    let header = Data(#"{"alg":"PBES2-HS256+A128KW","enc":"A256GCM"}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
    try Data((header + ".a.b.c.d").utf8).write(to: file)
    #expect(chmod(file.path, 0o600) == 0)
    let snapshot = try await vault.snapshot()
    #expect(snapshot.entries == 1 && snapshot.securePermissions && snapshot.jweHeadersMatch)
    try await vault.cleanup()
    #expect(!bridgeFileExists(vault.directory.path))
    #expect(bridgeFileExists(workspace.root.path))
    await #expect(throws: IsolatedAWSVaultRunner.Failure.closed) { try await vault.prepare() }
}

@Test func isolatedVaultCleanupRefusesToFollowAnUnexpectedSymlink() async throws {
    let workspace = try StubWorkspace()
    let vault = IsolatedAWSVaultRunner(parent: workspace.root, profile: "synthetic", process: FakeProcess())
    _ = try await vault.prepare()
    let outside = workspace.root.appendingPathComponent("outside-isolation")
    try Data("synthetic".utf8).write(to: outside)
    let link = vault.directory.appendingPathComponent("unexpected-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    await #expect(throws: IsolatedAWSVaultRunner.Failure.unsafeStorage) { try await vault.cleanup() }
    #expect(try Data(contentsOf: outside) == Data("synthetic".utf8))
    try FileManager.default.removeItem(at: link)
    try await vault.cleanup()
    #expect(bridgeFileExists(outside.path))
}

@Test func isolatedVaultRejectsPlaintextOrLoosePermissionStorageBeforeProcessLaunch() async throws {
    let workspace = try StubWorkspace()
    let process = FakeProcess()
    let vault = IsolatedAWSVaultRunner(parent: workspace.root, profile: "synthetic", process: process)
    _ = try await vault.prepare()
    let file = vault.directory.appendingPathComponent("synthetic-unsafe")
    try Data("synthetic plaintext".utf8).write(to: file)
    #expect(chmod(file.path, 0o644) == 0)
    await #expect(throws: IsolatedAWSVaultRunner.Failure.unsafeStorage) {
        try await vault.run(ProcessRequest(
            executable: URL(fileURLWithPath: "/tools/aws-vault"), arguments: isolatedArguments, environment: [:], timeout: 5
        ), progress: { _ in })
    }
    #expect(await process.requests().isEmpty)
    try await vault.cleanup()
}
#endif
