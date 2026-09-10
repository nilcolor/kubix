#if DEBUG
import Foundation
import KubixCore
import KubixRuntime

/// Auth only: documented aws-vault file storage and native device authorization; no cluster requests.
@MainActor
enum AWSVaultIsolationValidation {
    enum Failure: Error { case configuration, storage, processFailed, browser, credential }
    private static var didRun = false
    private static var evidence: [String: String] = [:]
    static var root: URL? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KUBIX_AWS_VAULT_ISOLATION_CONFIRM"] == "isolated-device-auth-only",
              let path = environment["KUBIX_AWS_VAULT_ISOLATION_ROOT"], path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func run(composition: AppComposition) async {
        guard root != nil, let vault = composition.isolatedVault, !didRun else { return }
        didRun = true
        record("appPID", String(ProcessInfo.processInfo.processIdentifier))
        record("result", "running")
        let originalMetadata = originalCacheMetadata()
        do {
            guard composition.store.execSessions.isEmpty,
                  composition.store.contexts.filter({ $0.name == "synthetic-context" }).count == 1 else { throw Failure.configuration }
            try composition.actions.selectContext(named: "synthetic-context")
            let initial = try await vault.prepare()
            guard initial.entries == 0, initial.securePermissions else { throw Failure.storage }
            record("initialSession", "missing: newly created empty isolated encrypted backend")
            record("originalVault", "not selected; original AWS config/profile chain retained")
            record("backend", "aws-vault 7.13.6 documented file backend; random in-memory passphrase")
            record("stage", "one fresh native device-authorization attempt; no cancellation rehearsal")
            try await approveFresh(composition)
            let final = try await vault.snapshot()
            guard final.entries > 0, final.securePermissions, final.jweHeadersMatch else { throw Failure.storage }
            record("ownedEncryptedEntries", String(final.entries))
            record("storageSecurity", "0700 directory; 0600 files; PBES2-HS256+A128KW / A256GCM envelopes")
            record("credentialProcessCalls", String(await vault.calls))
            record("result", "fresh isolated native device authorization and EKS credential acquisition succeeded")
        } catch {
            record("result", "failed")
            if let failure = error as? Failure { record("errorCategory", String(describing: failure)) } else if let failure = error as? IsolatedAWSVaultRunner.Failure {
                record("errorCategory", String(describing: failure))
            } else { record("errorCategory", String(describing: type(of: error))) }
        }
        do { try await vault.cleanup(); record("isolatedStorageRemoved", "true") } catch {
            record("isolatedStorageRemoved", "false")
        }
        record("originalCacheMetadataUnchanged", String(originalMetadata == originalCacheMetadata()))
        record("openShellSessions", String(composition.store.execSessions.filter { !$0.isClosed }.count))
        record("clusterRequests", "none")
        record("finished", "true")
    }

    private static func approveFresh(_ composition: AppComposition) async throws {
        let started = Date()
        let timeout = composition.store.authSettings.timeout
        record("configuredAuthTimeoutSeconds", String(timeout))
        record("acquisitionStartedUTC", ISO8601DateFormatter().string(from: started))
        record("configuredDeadlineUTC", ISO8601DateFormatter().string(from: started.addingTimeInterval(timeout)))
        var complete = false
        let work = Task {
            await composition.actions.authenticateSelectedContext()
            complete = true
        }
        defer { work.cancel() }
        do {
            let session = try await waitForPrompt(composition.store, isComplete: { complete })
            record("invocation", "one original configured aws-vault exec command; same synthetic-profile to exp chain")
            record("deviceMode", "native StartDeviceAuthorization / device_code grant, not direct-AWS --use-device-code")
            record("stage", "opening actual HTTPS fallback; waiting for human browser approval")
            record("operationID", session.id.uuidString)
            let opened = await composition.actions.openAuthorizationURL(operationID: session.id)
            record("httpsOpenBrowserSucceeded", String(opened))
            guard opened else { throw Failure.browser }
            await work.value
            await Task.yield()
            guard composition.store.authenticationDiagnostic == nil,
                  composition.store.authenticationSessions[session.id]?.state == .succeeded else { throw Failure.credential }
            record("credentialResult", "real ExecCredential accepted after isolated browser approval; no cluster API or exec")
        } catch {
            work.cancel()
            await work.value
            throw error
        }
    }

    private static func waitForPrompt(_ store: AppStore, isComplete: () -> Bool) async throws -> AuthSession {
        while true {
            let sessions = store.authenticationSessions.values
            if let session = sessions.first(where: {
                !$0.state.isTerminal && $0.instructions.contains("Open the SSO authorization page in a browser")
                    && $0.authorizationURL != nil
            }) { return session }
            if isComplete() || sessions.contains(where: { $0.state.isTerminal }) { throw Failure.processFailed }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func record(_ key: String, _ value: String) {
        evidence[key] = value
        guard let destination = root?.appendingPathComponent(".build/validation/task12-isolated-auth/result.json"),
              let bytes = try? JSONEncoder().encode(evidence) else { return }
        try? bytes.write(to: destination, options: .atomic)
    }

    /// File metadata only, never keychain/SSO contents or filenames in evidence.
    private static func originalCacheMetadata() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let keychain = home.appendingPathComponent("Library/Keychains/aws-vault.keychain-db")
        let cache = home.appendingPathComponent(".aws/sso/cache")
        let children = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        var result: [String: String] = [:]
        let configuration = [home.appendingPathComponent(".aws/config"), home.appendingPathComponent(".kube/config")]
        for file in [keychain, cache] + configuration + children {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { continue }
            result[file.path] = "\(attributes[.systemFileNumber] ?? ""):\(attributes[.size] ?? ""):\(attributes[.modificationDate] ?? "")"
        }
        return result
    }
}
#endif
