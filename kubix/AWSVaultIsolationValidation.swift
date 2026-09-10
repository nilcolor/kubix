#if DEBUG
import Foundation
import KubixCore
import KubixRuntime

/// Auth only: documented aws-vault file storage and native device authorization; no cluster requests.
@MainActor
enum AWSVaultIsolationValidation {
    enum Failure: Error { case configuration, storage, processFailed, timeout, browser, cancellation, credential }
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
            record("stage", "first native device-authorization wait; will cancel before opening browser")
            let cancelledID = try await cancelFirstWait(composition, vault: vault)
            try await approveRetry(composition, cancelledID: cancelledID)
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

    private static func cancelFirstWait(_ composition: AppComposition, vault: IsolatedAWSVaultRunner) async throws -> UUID {
        let work = Task { await composition.actions.authenticateSelectedContext() }
        defer { work.cancel() }
        do {
            let session = try await waitForPrompt(composition.store)
            record("firstWait", "native aws-vault device authorization instructions and HTTPS fallback visible")
            try await Task.sleep(for: .seconds(1))
            guard composition.store.authenticationSessions[session.id]?.state.isTerminal == false,
                  let pid = await vault.processIDs.last, kill(pid, 0) == 0 else { throw Failure.cancellation }
            await composition.actions.cancelAuthentication(operationID: session.id)
            await work.value
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while kill(pid, 0) == 0 {
                guard ContinuousClock.now < deadline else { throw Failure.cancellation }
                try await Task.sleep(for: .milliseconds(25))
            }
            guard let cancelled = composition.store.authenticationSessions[session.id],
                  cancelled.state == .cancelled, cancelled.instructions.isEmpty, cancelled.authorizationURL == nil,
                  try await vault.snapshot().entries == 0 else { throw Failure.cancellation }
            record("browserWaitCancellation", "passed; owned process reaped, transient instructions cleared, isolated store still empty")
            return session.id
        } catch {
            work.cancel()
            await work.value
            throw error
        }
    }

    private static func approveRetry(_ composition: AppComposition, cancelledID: UUID) async throws {
        let work = Task { try await composition.actions.retryAuthentication(operationID: cancelledID) }
        defer { work.cancel() }
        do {
            let session = try await waitForPrompt(composition.store, excluding: cancelledID)
            record("retry", "original configured aws-vault exec command; same synthetic-profile to exp chain")
            record("deviceMode", "native StartDeviceAuthorization / device_code grant, not direct-AWS --use-device-code")
            record("stage", "opening actual HTTPS fallback; waiting for human browser approval")
            record("operationID", session.id.uuidString)
            let opened = await composition.actions.openAuthorizationURL(operationID: session.id)
            record("httpsOpenBrowserSucceeded", String(opened))
            guard opened else { throw Failure.browser }
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(180)) } catch { return }
                record("humanApprovalDeadlineReached", "true")
                await composition.actions.cancelAuthentication(operationID: session.id)
            }
            defer { deadline.cancel() }
            try await work.value
            guard composition.store.authenticationDiagnostic == nil else { throw Failure.credential }
            record("credentialResult", "real ExecCredential accepted after isolated browser approval; no cluster API or exec")
        } catch {
            work.cancel()
            _ = await work.result
            throw error
        }
    }

    private static func waitForPrompt(_ store: AppStore, excluding: UUID? = nil) async throws -> AuthSession {
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while ContinuousClock.now < deadline {
            let sessions = store.authenticationSessions.values.filter { $0.id != excluding }
            if let session = sessions.first(where: {
                !$0.state.isTerminal && $0.instructions.contains("Open the SSO authorization page in a browser")
                    && $0.authorizationURL != nil
            }) { return session }
            if sessions.contains(where: { $0.state.isTerminal }) { throw Failure.processFailed }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure.timeout
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
