#if DEBUG
import Foundation
import KubixCore

/// Opt-in sign-in only, using the same action as the button. Never opens or resumes a shell.
@MainActor
enum AuthLoginValidation {
    private static var didRun = false

    static func run(composition: AppComposition) async {
        let environment = ProcessInfo.processInfo.environment
        guard !didRun, environment["KUBIX_AUTH_VALIDATION_CONFIRM"] == "sign-in-only",
              let name = environment["KUBIX_AUTH_VALIDATION_CONTEXT"], !name.isEmpty,
              let directory = environment["KUBIX_AUTH_VALIDATION_DIRECTORY"], directory.hasPrefix("/") else { return }
        let action = environment["KUBIX_AUTH_VALIDATION_ACTION"] ?? "aws-sso"
        guard ["aws-sso", "configured-plugin"].contains(action) else { return }
        let configuredPlugin = action == "configured-plugin"
        didRun = true
        let store = composition.store
        let actions = composition.actions
        let destination = URL(fileURLWithPath: directory).appendingPathComponent("auth-result.json")
        var evidence = [
            "appPID": String(ProcessInfo.processInfo.processIdentifier),
            "initialSSOState": "unknown; no shared cache inspected or cleared",
            "action": "not attempted",
            "result": "context unavailable or nonempty shell session state"
        ]
        guard store.contexts.filter({ $0.name == name }).count == 1, store.execSessions.isEmpty else {
            write(evidence, to: destination)
            return
        }
        do { try actions.selectContext(named: name) } catch {
            write(evidence, to: destination)
            return
        }
        for _ in 0..<60 where store.pluginPresentation == AuthPluginPresentation() {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard store.selectedContext?.name == name, store.execSessions.isEmpty else { return }
        evidence["context"] = name
        evidence["executable"] = store.pluginPresentation.executable
        evidence["profile"] = store.pluginPresentation.profile
        evidence["buttonEnabled"] = String(
            configuredPlugin ? store.pluginPresentation.executable != nil : store.pluginPresentation.canSignIn
        )
        evidence["action"] = configuredPlugin ? "AppActions.authenticateSelectedContext" : "AppActions.signInSelectedContext"
        evidence["result"] = "awaiting sign-in action result"
        write(evidence, to: destination)
        let monitor = Task {
            while !Task.isCancelled {
                writeProgress(evidence, store: store, to: destination)
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        if configuredPlugin { await actions.authenticateSelectedContext() } else { await actions.signInSelectedContext() }
        monitor.cancel()
        await monitor.value
        writeResult(evidence, store: store, configuredPlugin: configuredPlugin, to: destination)
    }

    private static func writeResult(
        _ evidence: [String: String], store: AppStore, configuredPlugin: Bool, to destination: URL
    ) {
        var evidence = evidence
        evidence["shellSessionCount"] = String(store.execSessions.count)
        evidence["authSessionCount"] = String(store.authenticationSessions.count)
        if store.authenticationDiagnostic == AuthenticationError.unsupportedAWSInvocation.errorDescription {
            evidence["result"] = "unsupported AWS wrapper; rejected before login"
        } else if store.pluginPresentation.executable == nil,
                  store.pluginPresentation.diagnostic?.hasPrefix("Authentication plugin not found.") == true {
            evidence["result"] = "configured plugin not found; Configure Plugin Path required"
        } else if store.authenticationDiagnostic != nil {
            evidence["result"] = "authentication failed; inspect transient app diagnostic"
        } else if store.authenticationSessions.values.contains(where: { $0.state == .succeeded }) {
            evidence["result"] = configuredPlugin
                ? "configured credential acquisition succeeded; browser login not implied" : "login and credential acquisition succeeded"
        } else {
            evidence["result"] = "no successful authentication observed"
        }
        write(evidence, to: destination)
    }

    private static func writeProgress(_ evidence: [String: String], store: AppStore, to destination: URL) {
        var evidence = evidence
        let sessions = store.authenticationSessions.values
        evidence["authSessionCount"] = String(sessions.count)
        evidence["shellSessionCount"] = String(store.execSessions.count)
        evidence["liveInstructionsPresent"] = String(sessions.contains { !$0.instructions.isEmpty })
        evidence["browserFallbackAvailable"] = String(sessions.contains { $0.authorizationURL != nil })
        evidence["sessionStates"] = sessions.map { String(describing: $0.state) }.sorted().joined(separator: ",")
        write(evidence, to: destination)
    }

    private static func write(_ evidence: [String: String], to destination: URL) {
        if let data = try? JSONEncoder().encode(evidence) { try? data.write(to: destination, options: .atomic) }
    }
}
#endif
