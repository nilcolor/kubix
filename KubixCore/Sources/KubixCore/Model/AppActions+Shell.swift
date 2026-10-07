import Foundation

/// A shell session's own lifecycle: authenticate, validate the captured row, run the exec, and
/// allocate the terminal surface only once the transport has committed to the session.
extension AppActions {
    func start(_ session: ExecSession) {
        let attempt = UUID()
        attempts[session.id] = attempt
        tasks[session.id] = Task { [weak self, authentication, exec] in
            let result: ExecSessionResult
            do {
                _ = try await authentication.acquire(for: session.target.context)
                try Task.checkCancellation()
                guard self?.isCurrent(session.id, attempt: attempt) == true else { return }
                try self?.validatePodShell(session.id)
                self?.update(session.id, state: .connecting)
                result = await exec.run(
                    sessionID: session.id, target: session.target,
                    ready: { [weak self] endpoint in
                        guard let self, self.isCurrent(session.id, attempt: attempt), !Task.isCancelled else {
                            throw CancellationError()
                        }
                        try self.validatePodShell(session.id)
                        try self.createSurface(session, endpoint: endpoint)
                    },
                    update: { [weak self] state in
                        guard self?.isCurrent(session.id, attempt: attempt) == true else { return }
                        self?.update(session.id, state: state)
                    }
                )
            } catch {
                result = error is CancellationError ? .cancelled : .failed(.authentication(Self.authDiagnostic(error)))
            }
            guard self?.isCurrent(session.id, attempt: attempt) == true else { return }
            self?.finish(session.id, result: result)
            self?.tasks.removeValue(forKey: session.id)
            self?.attempts.removeValue(forKey: session.id)
        }
    }

    func createSurface(_ session: ExecSession, endpoint: ExecBridgeEndpoint) throws {
        let surface: any TerminalSurface
        do {
            surface = try surfaces.makeSurface(
                sessionID: session.id, target: session.target, endpoint: endpoint,
                onChildExit: { [weak self] in Task { await self?.childTerminated(session.id) } }
            )
        } catch { throw ExecFailure.surface }
        guard let index = index(session.id), !store.execSessions[index].isClosed else {
            surface.teardown()
            throw CancellationError()
        }
        lifetimes[session.id] = TerminalSurfaceLifetime(surface: surface)
        store.surfaceRevision += 1
    }

    func index(_ id: UUID) -> Int? { store.execSessions.firstIndex { $0.id == id } }

    func isCurrent(_ id: UUID, attempt: UUID) -> Bool {
        !stopped && attempts[id] == attempt && index(id).map { !store.execSessions[$0].isClosed } == true
    }

    func update(_ id: UUID, state: ExecSession.State) {
        guard let index = index(id), !store.execSessions[index].state.isTerminal else { return }
        if state == .running { podShellGuards.removeValue(forKey: id) }
        store.execSessions[index].state = state
    }

    func finish(_ id: UUID, result: ExecSessionResult) {
        update(id, state: .finished(result))
        guard case .exited(let code) = result, index(id).map({ !store.execSessions[$0].isClosed }) == true else {
            return
        }
        // A finished shell's pane holds nothing usable and cannot be reconnected, so it closes itself.
        // Only a *remote* exit qualifies: a failure keeps its pane, which carries the reason and Retry.
        // A nonzero code leaves a note, so a container without a shell does not exit within a second
        // and take its only explanation with it.
        if code != 0, let target = index(id).map({ store.execSessions[$0].target }) {
            store.podShellDiagnostic = "Shell in \(target.pod)/\(target.container) exited with code \(code)."
        }
        closeShell(id)
    }
}
