import Darwin
import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

#if DEBUG
@Test func validationLaunchObservationDoesNotReplaceRealProcessExecution() async throws {
    let capture = TextCapture()
    let runner = ProcessRunner(validationDidLaunch: { pid in
        #expect(pid > 0)
        capture.append("owned")
    })
    let result = try await runner.run(ProcessRequest(
        executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"], environment: [:], timeout: 5
    ), progress: { _ in })
    #expect(result.exitCode == 0 && capture.value == "owned")
}

@Test func readOnlyValidationShellDisablesHistoryAndStartupFilesWithoutChangingOrdinaryShell() throws {
    let target = try ExecTarget(context: runtimeContext(), namespace: "synthetic", pod: "pod", container: "regular")
    let validation = try ExecService.shellRequest(target, readOnlyValidation: true)
    let command = validation.apiRequest.query.filter { $0.name == "command" }.compactMap(\.value)
    #expect(command == [
        "env", "TERM=xterm-256color", "HISTFILE=", "HISTSIZE=0", "HISTFILESIZE=0", "ENV=", "BASH_ENV=",
        "sh", "-c", "command -v bash >/dev/null && exec bash --noprofile --norc || exec sh"
    ])
    let ordinary = try ExecService.shellRequest(target).apiRequest.query.filter { $0.name == "command" }.compactMap(\.value)
    #expect(ordinary == ["env", "TERM=xterm-256color", "sh", "-c", "command -v bash >/dev/null && exec bash || exec sh"])
    #expect(validation.apiRequest.path == ["api", "v1", "namespaces", "synthetic", "pods", "pod", "exec"])
}

@Test func validationBridgeUsesOwnedRepositoryRootAndCleansItsSocketAndDirectory() async throws {
    let root = try BridgeDirectoryCapture().create(suffix: "vtest-XXXXXX")
    defer { rmdir(root) }
    let server = PTYBridgeServer(validationRoot: URL(fileURLWithPath: root))
    let session = try await server.prepare(sessionID: UUID())
    let path = session.endpoint.socketPath
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    #expect(directory.hasPrefix(root + "/v-"))
    #expect(try bridgeFileMode(directory) == 0o700)
    #expect(try bridgeFileMode(path) == 0o600)
    await session.close()
    #expect(!bridgeFileExists(path) && !bridgeFileExists(directory))
}
#endif
