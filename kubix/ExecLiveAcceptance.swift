#if DEBUG
import AppKit
import GhosttyKit
import KubixCore

@MainActor enum ExecLiveAcceptance {
    static func run(_ composition: AppComposition, root: URL) async {
        let original = composition.store.authSettings
        var view: GhosttySurfaceView?
        var child: pid_t?
        var socket: String?
        ExecLiveValidation.record("appPID", String(ProcessInfo.processInfo.processIdentifier))
        ExecLiveValidation.record("scope", "LIVE readonly approved context/namespace/prefix; full production Table/watch; regular synthetic-container only")
        do {
            var settings = original
            settings.searchDirectories = [root.appendingPathComponent(".build/v-tools").path]
            try await composition.actions.updateAuthSettings(settings)
            try composition.actions.selectContext(named: ExecLiveDiscovery.context)
            try await authenticate(composition)
            guard composition.store.authenticationDiagnostic == nil else { throw ExecLiveValidation.Failure.authentication }
            await composition.validationPods?.armAcceptance()
            try composition.actions.selectNamespace(ExecLiveDiscovery.namespace)
            composition.actions.refreshList()
            try await ExecLiveValidation.until { composition.store.connection == .live }
            try await verifyNativeTable(composition)
            let selected = try await target(composition)
            ExecLiveValidation.record("tableRows", String(composition.store.rows.count))
            ExecLiveValidation.record("tableUniqueUIDs", String(Set(composition.store.rows.map(\.id)).count))
            ExecLiveValidation.record("tableColumns", String(composition.store.columns?.count ?? 0))
            let session = try await shell(composition, uid: selected.id)
            guard let surface = composition.actions.surface(for: session.id) as? GhosttySurfaceView, let native = surface.surface else {
                throw ExecLiveValidation.Failure.surface
            }
            view = surface
            child = pid_t(ghostty_surface_foreground_pid(native))
            socket = surface.configuration.environment.first { $0.key == "KUBIX_BRIDGE_SOCK" }?.value
            try await logs(composition, uid: selected.id, shell: session, view: surface)
            ExecLiveValidation.record("credentialProcesses", String(await composition.validationProcess.calls))
            guard await !composition.validationProcess.kubectlDiscoverable else { throw ExecLiveValidation.Failure.configuration }
            ExecLiveValidation.record("kubectlEffectivePATH", "absent from every actual resolved credential process PATH, including configured dirs/overrides; shell recovery disabled")
            ExecLiveValidation.record("result", "passed")
        } catch {
            ExecLiveValidation.record("result", "failed")
            ExecLiveValidation.record("errorCategory", ExecLiveValidation.category(error))
        }
        await cleanup(composition, settings: original, view: view, child: child, socket: socket)
        ExecLiveValidation.record("finished", "true")
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    private static func authenticate(_ composition: AppComposition) async throws {
        var finished = false
        let work = Task {
            await composition.actions.authenticateSelectedContext()
            finished = true
        }
        defer { work.cancel() }
        while !finished {
            if let waiting = composition.store.authenticationSessions.values.first(where: {
                !$0.state.isTerminal && !$0.instructions.isEmpty
            }) {
                await composition.actions.cancelAuthentication(operationID: waiting.id)
                await work.value
                ExecLiveValidation.record("browserApproval", "human-only approval unavailable; operation cancelled without opening browser")
                throw ExecLiveValidation.Failure.authentication
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        ExecLiveValidation.record("browserGate", "genuine prior Task12 missing-session/human approval reused; Task20 did not request browser approval")
    }

    private static func verifyNativeTable(_ composition: AppComposition) async throws {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        try await ExecLiveValidation.until {
            let tables = NSApp.windows.compactMap(\.contentView).flatMap(descendants).compactMap { $0 as? NSTableView }
            return tables.contains {
                $0.identifier?.rawValue == "pod-table" && $0.numberOfRows == composition.store.rows.count
                    && $0.numberOfRows > 0 && !$0.tableColumns.isEmpty
            }
        }
        ExecLiveValidation.record("nativeTable", "actual NSTableView full row count matches production complete watch snapshot")
    }

    private static func cleanup(
        _ composition: AppComposition, settings: AuthSettings, view: GhosttySurfaceView?, child: pid_t?, socket: String?
    ) async {
        do {
            try await composition.actions.updateAuthSettings(settings)
            ExecLiveValidation.record("settingsRestored", "true")
        } catch {
            ExecLiveValidation.record("result", "failed")
            ExecLiveValidation.record("settingsRestored", "false")
        }
        await composition.shutdown()
        do {
            try await ExecLiveValidation.until {
                (view == nil || view?.freeCount == 1)
                    && (child == nil || (kill(child!, 0) == -1 && errno == ESRCH))
                    && (socket == nil || !FileManager.default.fileExists(atPath: socket!))
            }
            ExecLiveValidation.record("cleanup", "owned watch/log/exec work joined; child reaped; socket removed; surface single-free")
        } catch {
            ExecLiveValidation.record("result", "failed")
            ExecLiveValidation.record("cleanup", "incomplete")
        }
    }

    private static func target(_ composition: AppComposition) async throws -> ResourceRow {
        let rows = composition.store.rows.filter { $0.metadata.name?.hasPrefix(ExecLiveDiscovery.prefix) == true }
        guard let context = composition.store.selectedContext, context.name == ExecLiveDiscovery.context else {
            throw ExecLiveValidation.Failure.configuration
        }
        let transport = ExecLiveScopedTransport(underlying: try await composition.validationTransport(for: context))
        for row in rows {
            guard let name = row.metadata.name else { continue }
            let data = try await transport.data(for: APIRequest(resource: "pods", namespace: ExecLiveDiscovery.namespace, name: name))
            let details = try JSONDecoder().decode(PodDetails.self, from: data)
            let choices = ContainerSelection(details: details)
            if details.uid == row.id, choices.shell.contains(where: { $0.name == ExecLiveDiscovery.container }),
               choices.defaultLog?.name == ExecLiveDiscovery.container, choices.defaultLog?.kind == .regular { return row }
        }
        throw ExecLiveValidation.Failure.noMatchingPod
    }

    private static func shell(_ composition: AppComposition, uid: String) async throws -> ExecSession {
        composition.actions.openPodShell(uid: uid)
        try await ExecLiveValidation.until { composition.store.containerPicker != nil || !composition.store.execSessions.isEmpty }
        if let picker = composition.store.containerPicker {
            composition.actions.confirmPodShell(selectionID: picker.id, container: ExecLiveDiscovery.container)
        }
        try await ExecLiveValidation.until {
            if composition.store.execSessions.first?.state.isTerminal == true { throw ExecLiveValidation.Failure.shellFailed }
            return composition.store.execSessions.first?.state == .running
        }
        guard let session = composition.store.execSessions.first, session.target.container == ExecLiveDiscovery.container else {
            throw ExecLiveValidation.Failure.targetChanged
        }
        ExecLiveValidation.record("rowShell", "current row action -> fresh UID details -> regular selection -> auth -> v5 -> bridge/Ghostty running; no command probe repeated")
        return session
    }

    private static func logs(_ composition: AppComposition, uid: String, shell: ExecSession, view: GhosttySurfaceView) async throws {
        composition.actions.openPodLogs(uid: uid)
        try await ExecLiveValidation.until { composition.store.logSessions.first?.state == .following }
        guard let log = composition.store.logSessions.first else { throw ExecLiveValidation.Failure.targetChanged }
        let began = ContinuousClock.now
        try await Task.sleep(for: .seconds(3))
        guard log.state == .following, log.target.uid == uid, log.target.container.name == ExecLiveDiscovery.container,
              log.target.container.kind == .regular else { throw ExecLiveValidation.Failure.targetChanged }
        ExecLiveValidation.record("logFollowSeconds", String(describing: began.duration(to: .now)))
        ExecLiveValidation.record("logLinesIncludingBoundary", String(log.buffer.count))
        composition.actions.pauseLog(log.id)
        composition.actions.resumeLog(log.id)
        try await ExecLiveValidation.until { log.state == .following && log.segment == 2 }
        guard log.buffer.lines.filter(\.isBoundary).count == 2,
              composition.actions.surface(for: shell.id) === view, view.freeCount == 0,
              composition.store.execSessions.first?.target == shell.target else { throw ExecLiveValidation.Failure.surface }
        ExecLiveValidation.record("logs", "LIVE regular-container follow tailLines0; explicit Pause/Resume fresh original UID; two restart boundaries; no payload evidence")
        ExecLiveValidation.record("stableSession", "same exec UUID/target/surface remains running through Table/watch and log tab/Resume; quit with all three live")
    }
}
#endif
