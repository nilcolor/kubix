import Foundation
import KubixCore

public protocol AuthMaterialReading: Sendable {
    func read(_ path: String) async throws -> Data
}

public struct LocalAuthMaterialReader: AuthMaterialReading {
    public init() {}
    public func read(_ path: String) async throws -> Data {
        try await Task.detached {
            do { return try Data(contentsOf: URL(fileURLWithPath: path)) } catch {
                throw AuthenticationError.materialUnavailable
            }
        }.value
    }
}

public struct CredentialRunner: Sendable {
    private let process: any ProcessRunning
    private let materials: any AuthMaterialReading

    public init(process: any ProcessRunning = ProcessRunner(), materials: any AuthMaterialReading = LocalAuthMaterialReader()) {
        self.process = process
        self.materials = materials
    }

    public func acquire(
        context: ResolvedContext, plugin: ResolvedPlugin, progress: @escaping AuthProgress
    ) async throws -> Credential {
        guard case .exec(let configuration) = try AuthMethod.resolve(from: context) else {
            throw AuthError.execAuthenticationRequired
        }
        let version = try ExecCredential.validate(configuration)
        var caData: Data?
        if configuration.provideClusterInfo == true, case .file(let path) = context.cluster.certificateAuthoritySource {
            caData = try await materials.read(path)
        }
        let info = try ExecCredential.Request(from: context, certificateAuthorityFileData: caData).encoded()
        var environment = plugin.environment
        environment["KUBERNETES_EXEC_INFO"] = String(decoding: info, as: UTF8.self)
        try Task.checkCancellation()
        let result = try await process.run(ProcessRequest(
            executable: plugin.executable, arguments: configuration.args ?? [], environment: environment,
            timeout: plugin.settings.timeout
        ), progress: progress)
        guard result.exitCode == 0 else { throw ProcessFailure.exited(result.exitCode) }
        return try ExecCredential.Response(data: result.stdout, expectedVersion: version).credential
    }
}
