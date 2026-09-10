import Foundation

public extension AppActions {
    func selectLog(_ id: UUID) {
        guard logSession(id) != nil else { return }
        store.selectedLogSessionID = id
    }

    func setLogFilter(_ id: UUID, _ value: String) { logSession(id)?.filter = String(value.prefix(256)) }
    func setLogAutoscroll(_ id: UUID, _ value: Bool) { logSession(id)?.autoscroll = value }

    func pauseLog(_ id: UUID) {
        guard let session = logSession(id) else { return }
        if let attempt = logAttempts[id] { logTasks[attempt]?.cancel() }
        session.state = .paused
    }

    func closeLog(_ id: UUID) {
        guard let session = logSession(id) else { return }
        pauseLog(id)
        session.isClosed = true
        // Closed log payloads are not a history store.
        session.buffer = LogBuffer()
        logAttempts.removeValue(forKey: id)
        podLogGuards.removeValue(forKey: id)
        store.logSessions.removeAll { $0.id == id }
        if store.selectedLogSessionID == id { store.selectedLogSessionID = store.logSessions.last?.id }
    }

    func resumeLog(_ id: UUID) { revalidateLog(id, container: nil) }

    func switchLogContainer(_ id: UUID, name: String) {
        guard let session = logSession(id), name != session.target.container.name,
              session.containers.contains(where: { $0.name == name }) else { return }
        revalidateLog(id, container: name)
    }
}

extension AppActions {
    func logSession(_ id: UUID) -> LogSession? { store.logSessions.first { $0.id == id && !$0.isClosed } }

    func pauseLogsForScopeChange() {
        for session in store.logSessions {
            pauseLog(session.id)
            // Invalidate even an uncooperative detail/stream callback after the scope change.
            logAttempts.removeValue(forKey: session.id)
        }
    }

    func startLog(_ session: LogSession) {
        guard let logs, !stopped else { return }
        let attempt = UUID()
        logAttempts[session.id] = attempt
        session.beginSegment()
        logTasks[attempt] = Task { [weak self] in
            defer { self?.logTasks.removeValue(forKey: attempt) }
            do {
                let request = try LogRequest(namespace: session.target.namespace, pod: session.target.pod, container: session.target.container.name)
                let outcome = await logs.run(target: session.target, request: request) { [weak self] event in
                    self?.receiveLog(event, session: session, attempt: attempt)
                }
                guard self?.logIsCurrent(session, attempt: attempt) == true else { return }
                self?.finishLog(outcome, session: session)
            } catch {
                if self?.logIsCurrent(session, attempt: attempt) == true { session.state = .failed(LogFailure.classify(error)) }
            }
        }
    }

    private func receiveLog(_ event: LogEvent, session: LogSession, attempt: UUID) {
        guard logIsCurrent(session, attempt: attempt) else { return }
        if let selection = podLogGuards[session.id], !isCurrentPodSelection(selection) { return }
        switch event {
        case .opened:
            guard !Task.isCancelled, session.state != .paused else { return }
            let selection = podLogGuards.removeValue(forKey: session.id)
            if podLogSelection?.id == selection?.id { podLogSelection = nil }
            session.state = .following
        case .lines(let lines):
            for line in lines { session.buffer.append(line) }
        }
    }

    private func finishLog(_ outcome: LogOutcome, session: LogSession) {
        switch outcome {
        case .completed: session.state = .completed
        case .cancelled: session.state = .paused
        case .interrupted(let failure): session.state = .interrupted(failure)
        case .failed(let failure): session.state = .failed(failure)
        }
    }

    private func logIsCurrent(_ session: LogSession, attempt: UUID) -> Bool {
        !stopped && !session.isClosed && logAttempts[session.id] == attempt
    }

    private func revalidateLog(_ id: UUID, container: String?) {
        guard !stopped, let session = logSession(id), let details = podDetails else { return }
        pauseLog(id)
        let attempt = UUID()
        logAttempts[id] = attempt
        guard !store.isLoadingConfiguration, store.selectedContext == session.target.context,
              store.selectedNamespace == session.target.namespace else {
            session.state = .failed(.unavailable)
            return
        }
        let revision = configurationRevision
        session.state = .connecting
        logTasks[attempt] = Task { [weak self] in
            defer { self?.logTasks.removeValue(forKey: attempt) }
            do {
                let target = session.target
                let pod = try await details.details(context: target.context, namespace: target.namespace, name: target.pod, uid: target.uid)
                try Task.checkCancellation()
                guard let self, self.logIsCurrent(session, attempt: attempt), revision == self.configurationRevision else { return }
                try Self.validateLogPod(pod, name: target.pod, namespace: target.namespace, uid: target.uid)
                let name = container ?? target.container.name
                guard let chosen = pod.containers.first(where: { $0.name == name }),
                      container != nil || chosen.kind == target.container.kind else { throw PodDetailsError.identityMismatch }
                if container != nil {
                    session.state = .paused
                    self.startLog(self.makeLogSession(context: target.context, pod: pod, container: chosen))
                } else {
                    session.containers = ContainerSelection(details: pod).logs
                    self.startLog(session)
                }
            } catch {
                guard let self, self.logIsCurrent(session, attempt: attempt) else { return }
                session.state = Task.isCancelled ? .paused : .failed(LogFailure.classify(error))
            }
        }
    }
}
