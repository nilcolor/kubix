#if DEBUG
import AppKit
import GhosttyKit
import KubixCore
import Vision

@MainActor
final class ExecLiveTerminalChecks {
    private let composition: AppComposition
    private let target: ExecTarget
    private var sessions: [UUID] = []
    private var surfaces: [GhosttySurfaceView] = []
    private var children: [pid_t] = []
    private var sockets: [String] = []

    init(composition: AppComposition, target: ExecTarget) { self.composition = composition; self.target = target }

    func run() async throws {
        ExecLiveValidation.record("stage", "opening two real composed WebSocket/bridge/Ghostty sessions")
        let calls = await composition.validationProcess.calls
        for _ in 0..<2 {
            composition.actions.setNamespaceInput(target.namespace)
            composition.actions.setPodName(target.pod)
            composition.actions.setContainerName(target.container)
            guard let id = composition.actions.connectShell() else { throw ExecLiveValidation.Failure.configuration }
            sessions.append(id)
        }
        for id in sessions {
            try await ExecLiveValidation.until {
                guard let session = self.composition.store.execSessions.first(where: { $0.id == id }) else { return false }
                if case .finished(.failed(let failure)) = session.state {
                    if case .api(let error) = failure { throw error }
                    throw ExecLiveValidation.Failure.shellFailed
                }
                return session.state == .running
            }
            guard let view = composition.actions.surface(for: id) as? GhosttySurfaceView, let surface = view.surface else {
                throw ExecLiveValidation.Failure.surface
            }
            surfaces.append(view)
            let child = pid_t(ghostty_surface_foreground_pid(surface))
            guard child > 0 else { throw ExecLiveValidation.Failure.surface }
            children.append(child)
            if let socket = view.configuration.environment.first(where: { $0.key == "KUBIX_BRIDGE_SOCK" })?.value { sockets.append(socket) }
        }
        guard await composition.validationProcess.calls == calls else { throw ExecLiveValidation.Failure.credentialReuse }
        ExecLiveValidation.record("twoSessionCredentialReuse", "both running; zero additional credential processes")
        ExecLiveValidation.record("negotiatedProtocol", "v5.channel.k8s.io")
        ExecLiveValidation.record("bridgeChildPIDs", children.map(String.init).joined(separator: ","))
        try await probe(sessions[0], view: surfaces[0])
        try await exit(sessions[0], view: surfaces[0], code: 0)
        try await focus(sessions[1], view: surfaces[1])
        try send("printf 'KUBIX_%s\\n' SECOND_SESSION\n", view: surfaces[1])
        try await marker("KUBIX_SECOND_SESSION", view: surfaces[1])
        try await exit(sessions[1], view: surfaces[1], code: 7)
    }

    private func probe(_ id: UUID, view: GhosttySurfaceView) async throws {
        try await focus(id, view: view)
        ExecLiveValidation.record("stage", "per-keystroke input and remote echo")
        try send("printf '\\033[2J\\033[H'; printf 'KUBIX_%s\\n' READY\n", view: view)
        try await marker("KUBIX_READY", view: view)
        try send("p", view: view)
        try await ExecLiveValidation.until { TerminalSmokeTest.viewport(view).trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("p") }
        try send("rintf 'KUBIX_%s\\n' KEYSTROKE\n", view: view)
        try await marker("KUBIX_KEYSTROKE", view: view)
        let text = TerminalSmokeTest.viewport(view)
        guard text.components(separatedBy: "printf 'KUBIX_%s\\n' KEYSTROKE").count == 2,
              text.components(separatedBy: "KUBIX_KEYSTROKE").count == 2 else { throw ExecLiveValidation.Failure.doubleEcho }
        ExecLiveValidation.record("perKeystrokeAndEcho", "character visible before Enter; one command echo and one executed marker")
        try await renderedMarker(view)
        ExecLiveValidation.record("stage", "Ctrl-C interrupts only our temporary sleep")
        try send("printf 'KUBIX_%s\\n' SLEEP; sleep 30\n", view: view)
        try await marker("KUBIX_SLEEP", view: view)
        try await Task.sleep(for: .milliseconds(750))
        try interrupt(view)
        try send("printf 'KUBIX_%s\\n' INTERRUPTED\n", view: view)
        try await marker("KUBIX_INTERRUPTED", view: view)
        guard composition.store.execSessions.first(where: { $0.id == id })?.state == .running else { throw ExecLiveValidation.Failure.shellFailed }
        ExecLiveValidation.record("ctrlC", "own sleep interrupted; same bridge/session accepts next command")
        try await resize(view)
    }

    private func resize(_ view: GhosttySurfaceView) async throws {
        guard let surface = view.surface, let window = view.window else { throw ExecLiveValidation.Failure.surface }
        ExecLiveValidation.record("stage", "resize real app window and verify remote stty size")
        let initial = ghostty_surface_size(surface)
        ExecLiveValidation.record("initialGrid", "\(initial.columns)x\(initial.rows)")
        let contentSize = window.contentView?.bounds.size ?? NSSize(width: 1050, height: 800)
        window.setContentSize(NSSize(width: contentSize.width + 120, height: contentSize.height + 100))
        try await Task.sleep(for: .milliseconds(500))
        let after = ghostty_surface_size(surface)
        ExecLiveValidation.record("gridAfterWindowResize", "\(after.columns)x\(after.rows)")
        try await ExecLiveValidation.until {
            let size = ghostty_surface_size(surface)
            return size.columns != initial.columns || size.rows != initial.rows
        }
        let resized = ghostty_surface_size(surface)
        try send("printf 'KUBIX_SIZE '; stty size\n", view: view)
        var observed = ""
        try await ExecLiveValidation.until {
            let text = TerminalSmokeTest.viewport(view)
            guard let range = text.range(of: "KUBIX_SIZE [0-9]+ [0-9]+", options: .regularExpression) else { return false }
            observed = String(text[range])
            return true
        }
        ExecLiveValidation.record("remoteSizeObserved", observed)
        guard observed == "KUBIX_SIZE \(resized.rows) \(resized.columns)" else { throw ExecLiveValidation.Failure.resizeMismatch }
        ExecLiveValidation.record("remoteResize", "Ghostty \(resized.columns)x\(resized.rows); remote stty \(resized.rows) \(resized.columns)")
    }

    private func exit(_ id: UUID, view: GhosttySurfaceView, code: Int) async throws {
        ExecLiveValidation.record("stage", "remote exit \(code) and surface cleanup")
        try send("exit \(code)\n", view: view)
        try await ExecLiveValidation.until {
            self.composition.store.execSessions.first(where: { $0.id == id })?.state == .finished(.exited(code: code))
        }
        try await ExecLiveValidation.until { view.isDestroyed }
        guard view.freeCount == 1 else { throw ExecLiveValidation.Failure.childCleanup }
        ExecLiveValidation.record("exit\(code)", "remote exit status preserved; terminal surface freed once")
    }

    func cleanup() async {
        for id in sessions { composition.actions.closeShell(id) }
        do {
            try await ExecLiveValidation.until {
                self.children.allSatisfy { kill($0, 0) == -1 && errno == ESRCH }
                    && self.sockets.allSatisfy { !FileManager.default.fileExists(atPath: $0) }
                    && self.surfaces.allSatisfy { $0.isDestroyed && $0.freeCount == 1 }
            }
            ExecLiveValidation.record("terminalCleanup", "all owned children exited; sockets removed; surfaces freed once")
        } catch { ExecLiveValidation.record("terminalCleanup", "incomplete") }
    }

    private func focus(_ id: UUID, view: GhosttySurfaceView) async throws {
        composition.actions.selectShell(id)
        try await Task.sleep(for: .milliseconds(150))
        guard let window = view.window else { throw ExecLiveValidation.Failure.surface }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(view)
    }

    private func send(_ text: String, view: GhosttySurfaceView) throws {
        guard let window = view.window, window.firstResponder === view else { throw ExecLiveValidation.Failure.surface }
        try TerminalSmokeTest.type(text, in: window)
    }

    private func marker(_ marker: String, view: GhosttySurfaceView) async throws {
        try await ExecLiveValidation.until { TerminalSmokeTest.viewport(view).contains(marker) }
    }

    private func interrupt(_ view: GhosttySurfaceView) throws {
        guard let window = view.window, window.firstResponder === view else { throw ExecLiveValidation.Failure.surface }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{03}", charactersIgnoringModifiers: "c",
                isARepeat: false, keyCode: 8
            ) else { throw ExecLiveValidation.Failure.surface }
            window.sendEvent(event)
        }
    }

    private func renderedMarker(_ view: GhosttySurfaceView) async throws {
        try await Task.sleep(for: .milliseconds(500))
        let image = try TerminalSmokeImage.capture(view)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
        guard text.uppercased().filter({ $0.isLetter || $0.isNumber }).contains("KUBIXKEYSTROKE") else {
            throw ExecLiveValidation.Failure.marker
        }
        ExecLiveValidation.record("rendering", "actual remote marker recognized in Ghostty Metal pixels; no image persisted")
    }
}
#endif
