#if DEBUG
import Foundation
import KubixCore
import KubixRuntime

/// Fixed, opt-in Task12 scope. Not a listener, arbitrary command API, or background reconnect loop.
@MainActor
enum ExecLiveValidation {
    enum Failure: String, Error {
        case configuration, authentication, pagination, noMatchingPod, targetChanged, timeout, shellFailed
        case surface, marker, doubleEcho, childCleanup, serverFailureNotObserved, credentialReuse, resizeMismatch
    }
    private static var didRun = false
    private static var evidence: [String: String] = [:]
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["KUBIX_EXEC_VALIDATION_CONFIRM"] == "authorized-readonly-task12"
            && root != nil
    }
    private static var root: URL? {
        guard let path = ProcessInfo.processInfo.environment["KUBIX_EXEC_VALIDATION_ROOT"], path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
    static var bridgeRoot: URL? { isEnabled ? root?.appendingPathComponent(".build") : nil }
    private static var resultURL: URL? { root?.appendingPathComponent(".build/validation/task12-live-exec/result.json") }

    static func record(_ key: String, _ value: String) {
        evidence[key] = value
        if let url = resultURL, let bytes = try? JSONEncoder().encode(evidence) { try? bytes.write(to: url, options: .atomic) }
    }

    static func run(composition: AppComposition) async {
        guard isEnabled, !didRun, let root else { return }
        didRun = true
        record("appPID", String(ProcessInfo.processInfo.processIdentifier))
        record("scope", "read-only synthetic-namespace / authorized dj-slow prefix / regular synthetic-container")
        record("initialSSOState", "unknown; shared caches untouched; prior browser success user-confirmed")
        let original = composition.store.authSettings
        var terminal: ExecLiveTerminalChecks?
        do {
            guard composition.store.execSessions.isEmpty,
                  composition.store.contexts.filter({ $0.name == ExecLiveDiscovery.context }).count == 1 else {
                throw Failure.configuration
            }
            try composition.actions.selectContext(named: ExecLiveDiscovery.context)
            var settings = original
            settings.searchDirectories = [root.appendingPathComponent(".build/v-tools").path]
            try await composition.actions.updateAuthSettings(settings)
            record("stage", "acquiring configured-plugin credentials; human approval only if naturally needed")
            try await authenticate(composition)
            guard composition.store.authenticationDiagnostic == nil else { throw Failure.authentication }
            let target = try await discover(composition)
            let checks = ExecLiveTerminalChecks(composition: composition, target: target)
            terminal = checks
            try await checks.run()
            record("stage", "nonexistent executable server-failure probe on the same authorized target")
            try await serverFailure(target, transport: composition.validationTransport(for: target.context))
            record("credentialProcessCalls", String(await composition.validationProcess.calls))
            record("kubectlDiscoverable", String(await composition.validationProcess.kubectlDiscoverable))
            record("result", "remote terminal probes completed; historical/browser subgates require separate accounting")
        } catch {
            record("result", "failed")
            record("errorCategory", category(error))
            record("trustErrorCodes", composition.validationTransportFactory.trustErrorCodes.map(String.init).joined(separator: ","))
            record("trustAnchorCount", String(composition.validationTransportFactory.anchorCount))
            for (key, value) in composition.validationTransportFactory.trustDiagnostics { record("tls." + key, String(value)) }
        }
        await terminal?.cleanup()
        do { try await composition.actions.updateAuthSettings(original); record("appSettingsRestored", "true") } catch {
            record("appSettingsRestored", "false")
        }
        record("openShellSessions", String(composition.store.execSessions.filter { !$0.isClosed }.count))
        record("finished", "true")
    }

    private static func discover(_ composition: AppComposition) async throws -> ExecTarget {
        guard let context = composition.store.selectedContext, context.name == ExecLiveDiscovery.context else { throw Failure.configuration }
        let transport = try await composition.validationTransport(for: context)
        record("stage", "GET namespaced pod pages, filter authorized prefix, GET selected matching pod")
        let (pod, pages) = try await ExecLiveDiscovery.select(using: transport)
        record("pod", pod.metadata.name)
        record("podUID", pod.metadata.uid)
        record("container", ExecLiveDiscovery.container)
        record("containerRunning", "true")
        record("containerReady", String(pod.ready))
        record("listPages", String(pages))
        let bytes = try await transport.data(for: APIRequest(resource: "version", apiPath: []))
        let version = try JSONDecoder().decode(ExecLiveDiscovery.Version.self, from: bytes)
        record("serverVersion", version.gitVersion)
        return try ExecTarget(
            context: context, namespace: ExecLiveDiscovery.namespace, pod: pod.metadata.name, container: ExecLiveDiscovery.container
        )
    }

    private static func authenticate(_ composition: AppComposition) async throws {
        let work = Task { await composition.actions.authenticateSelectedContext() }
        defer { work.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var cancellation: (UUID, Int32)?
        while ContinuousClock.now < deadline {
            if let session = composition.store.authenticationSessions.values.first(where: { !$0.state.isTerminal }),
               let pid = await composition.validationProcess.launchedPIDs.last, kill(pid, 0) == 0 {
                cancellation = (session.id, pid)
                break
            }
            if composition.store.authenticationSessions.values.contains(where: { $0.state.isTerminal }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if let (id, pid) = cancellation {
            await composition.actions.cancelAuthentication(operationID: id)
            await work.value
            try await until { kill(pid, 0) == -1 && errno == ESRCH }
            record("credentialCancellation", "real owned plugin process cancelled and reaped; not browser-wait cancellation")
            try await composition.actions.retryAuthentication(operationID: id)
            record("credentialRetry", "explicit original configured-plugin Retry succeeded")
        } else {
            await work.value
            record("credentialCancellation", "not observed; acquisition completed before safe cancellation")
        }
    }

    private static func serverFailure(_ target: ExecTarget, transport: any Transport) async throws {
        let request = try ExecRequest(
            namespace: target.namespace, pod: target.pod, container: target.container,
            command: ["/kubix-readonly-validation-no-such-executable-9db6c94b"], stdin: false, tty: false
        )
        do {
            let socket = try await transport.webSocket(for: request.apiRequest)
            record("negotiatedProtocol", socket.negotiatedProtocol ?? "none")
            let deadline = Task { try? await Task.sleep(for: .seconds(20)); if !Task.isCancelled { socket.cancel() } }
            defer { deadline.cancel(); socket.cancel() }
            for _ in 0..<16 {
                if case .error(let bytes) = try await RemoteCommandFrame(data: socket.receive()) {
                    switch ExecOutcome(statusData: bytes) {
                    case .remoteFailure(let status):
                        guard status.reason == "InternalError",
                              status.message?.contains("kubix-readonly-validation-no-such-executable-9db6c94b") == true else {
                            throw Failure.serverFailureNotObserved
                        }
                        record("serverExecutionFailure", "remote InternalError references nonexistent executable; not normal exit127")
                        return
                    case .remoteExit(let code):
                        record("serverExecutionFailure", "normal exit \(code); not server-failure proof")
                    default: break
                    }
                    break
                }
            }
        } catch let error as APIError where error.httpCode == 500 {
            guard case .status(let status, _, _) = error, status.reason == "InternalError",
                  status.message?.contains("kubix-readonly-validation-no-such-executable-9db6c94b") == true else { throw error }
            record("serverExecutionFailure", "HTTP500 before upgrade for nonexistent executable")
            return
        }
        throw Failure.serverFailureNotObserved
    }

    static func until(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while try !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func category(_ error: any Error) -> String {
        if let failure = error as? Failure { return failure.rawValue }
        if let failure = error as? AuthenticationError {
            return "authentication." + String(describing: failure)
        }
        if let error = error as? APIError {
            switch error {
            case .transport(let value): return "transport." + value.rawValue
            case .tls(let value): return "tls." + value.rawValue
            case .unsupportedProtocol: return "unsupportedProtocol"
            default: return "HTTP." + String(error.httpCode ?? 0)
            }
        }
        return String(describing: type(of: error))
    }
}
#endif
