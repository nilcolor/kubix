import Foundation

public extension AppActions {
    func selectLog(_ id: UUID) {
        guard logSession(id) != nil else { return }
        store.selectedSession = .logs(id)
    }

    func setLogFilter(_ id: UUID, _ value: String) { logSession(id)?.filter = String(value.prefix(256)) }
    func setLogAutoscroll(_ id: UUID, _ value: Bool) { logSession(id)?.autoscroll = value }

    /// Pause stops every stream the tab holds. The flag is what makes it the user's pause rather than
    /// a guess from cancelled sources, which look the same from the outside.
    ///
    /// The attempts stay registered: a cancelled stream flushes the partial line it was holding, and
    /// those bytes were logged before the pause and belong in the buffer.
    func pauseLog(_ id: UUID) {
        guard let session = logSession(id) else { return }
        session.isPaused = true
        for source in session.sources { retireSource(source.id) }
        // A resolution in flight belongs to the tab, not to a source, and would otherwise install
        // the pods it found into a tab the user has paused.
        retireResolution(id)
    }

    func closeLog(_ id: UUID) {
        guard let session = logSession(id) else { return }
        pauseLog(id)
        session.isClosed = true
        // Closed log payloads are not a history store.
        session.buffer = LogBuffer(sources: 1)
        for source in session.sources { invalidateSource(source.id) }
        session.sources = []
        podLogGuards.removeValue(forKey: id)
        retireResolution(id)
        store.logSessions.removeAll { $0.id == id }
        store.sessionOrder.removeAll { $0 == .logs(id) }
        if store.selectedSession == .logs(id) { store.selectedSession = store.lastOpenSession }
    }

    func resumeLog(_ id: UUID) { revalidateLog(id, container: nil) }

    func switchLogContainer(_ id: UUID, name: String) {
        guard let session = logSession(id), name != session.scope.container.name,
              session.containers.contains(where: { $0.name == name }) else { return }
        revalidateLog(id, container: name)
    }
}

extension AppActions {
    func logSession(_ id: UUID) -> LogSession? { store.logSessions.first { $0.id == id && !$0.isClosed } }

    func pauseLogsForScopeChange() {
        for session in store.logSessions {
            pauseLog(session.id)
            // Invalidate even an uncooperative stream callback after the scope change: unlike a
            // pause, nothing more from the old scope belongs in the buffer.
            for source in session.sources { invalidateSource(source.id) }
        }
    }

    /// An authoritative live snapshot is the only evidence that a pod is gone. It retires that pod's
    /// **source**, not the tab: a deployment's other pods are still delivering, and a tab reporting
    /// `deleted` while four streams run would be describing something that did not happen.
    func reconcileLogPods(_ update: ResourceListUpdate) {
        // Connecting/relist snapshots are not authoritative evidence of deletion, and a deployments
        // watch says nothing at all about which pods exist.
        guard update.kind == .pods, update.connection == .live else { return }
        let retained = Set(update.rows.map(\.id))
        for session in store.logSessions where !session.isClosed {
            guard session.scope.context == store.selectedContext,
                  session.scope.namespace == store.selectedNamespace, !session.isPaused else { continue }
            for source in session.sources where !source.state.isTerminal && !retained.contains(source.target.uid) {
                invalidateSource(source.id)
                let replaced = update.rows.contains { $0.metadata.name == source.target.pod }
                session.update(source.id, state: .failed(replaced ? .replaced : .deleted))
            }
            if session.sources.allSatisfy(\.state.isTerminal) { podLogGuards.removeValue(forKey: session.id) }
        }
    }

    /// Starts every source of a tab under one new segment boundary.
    func startLog(_ session: LogSession) {
        session.isPaused = false
        session.beginSegment()
        for source in session.sources { startSource(session, source: source) }
    }

    func startSource(_ session: LogSession, source: LogSource) {
        guard let logs, !stopped else { return }
        let attempt = UUID()
        logAttempts[source.id] = attempt
        session.update(source.id, state: .connecting)
        logTasks[attempt] = Task { [weak self] in
            defer { self?.logTasks.removeValue(forKey: attempt) }
            do {
                let target = source.target
                let request = try LogRequest(
                    namespace: target.namespace, pod: target.pod, container: target.container.name,
                    tailLines: Self.tailLines(for: session.sources.count)
                )
                let outcome = await logs.run(target: target, request: request) { [weak self] event in
                    self?.receiveLog(event, session: session, source: source, attempt: attempt)
                }
                guard self?.logIsCurrent(session, source: source.id, attempt: attempt) == true else { return }
                self?.finishSource(outcome, session: session, source: source.id)
            } catch {
                guard self?.logIsCurrent(session, source: source.id, attempt: attempt) == true else { return }
                session.update(source.id, state: .failed(LogFailure.classify(error)))
            }
        }
    }

    /// The initial tail is shared: 200 lines each across forty pods would evict the whole buffer
    /// before any of it was read, so the per-stream tail shrinks as the fan-out grows.
    static func tailLines(for sources: Int) -> Int {
        sources <= 1 ? 200 : max(20, 1_000 / sources)
    }

    /// Cancels the stream but leaves its attempt registered, so the partial line it flushes on the
    /// way out is still accepted — those bytes arrived before whatever stopped it.
    func retireSource(_ id: UUID) {
        guard let attempt = logAttempts[id] else { return }
        logTasks[attempt]?.cancel()
    }

    /// Cancels the stream and rejects everything it might still deliver. For an ending where later
    /// bytes would be wrong rather than merely late: a scope change, a replaced pod, a closed tab.
    func invalidateSource(_ id: UUID) {
        retireSource(id)
        logAttempts.removeValue(forKey: id)
    }

    func retireResolution(_ session: UUID) {
        guard let attempt = deploymentLogAttempts.removeValue(forKey: session) else { return }
        logTasks[attempt]?.cancel()
    }

    private func receiveLog(_ event: LogEvent, session: LogSession, source: LogSource, attempt: UUID) {
        guard logIsCurrent(session, source: source.id, attempt: attempt) else { return }
        if let selection = podLogGuards[session.id], !isCurrentPodScope(selection) { return }
        switch event {
        case .opened:
            guard !Task.isCancelled, !session.isPaused else { return }
            // The first stream to open releases the tab's selection guard: the request it was
            // protecting has been answered.
            if let selection = podLogGuards.removeValue(forKey: session.id), podLogSelection?.id == selection.id {
                podLogSelection = nil
            }
            session.update(source.id, state: .following)
        case .lines(let lines):
            let label = session.labelsLines ? source.label : nil
            for line in lines { session.buffer.append(line, source: label) }
        }
    }

    private func finishSource(_ outcome: LogOutcome, session: LogSession, source: UUID) {
        switch outcome {
        case .completed: session.update(source, state: .ended)
        // A cancelled stream was retired by Pause, a scope change or a replacement, each of which
        // has already recorded what it meant; nothing is overwritten here.
        case .cancelled: break
        case .interrupted(let failure): session.update(source, state: .interrupted(failure))
        case .failed(let failure): session.update(source, state: .failed(failure))
        }
    }

    private func logIsCurrent(_ session: LogSession, source: UUID, attempt: UUID) -> Bool {
        !stopped && !session.isClosed && logAttempts[source] == attempt
    }
}
