import Foundation

/// The deck's own vocabulary: one strip holds shells and log tails, so focusing, closing and
/// switching container are asked once, in terms of a session rather than of its kind.
public extension AppActions {
    func selectSession(_ selection: SessionSelection) {
        switch selection {
        case .shell(let id): selectShell(id)
        case .logs(let id): selectLog(id)
        }
    }

    func closeSession(_ selection: SessionSelection) {
        switch selection {
        case .shell(let id): closeShell(id)
        case .logs(let id): closeLog(id)
        }
    }

    func setDeckCollapsed(_ collapsed: Bool) { store.deckCollapsed = collapsed }

    /// Focus the pod's session for `container` if one is open, and otherwise open it. Either way the
    /// new session is validated the way a first one is: a log tail revalidates through its own
    /// target, and a shell reruns the selected row's details, so neither can reach a pod that is no
    /// longer the one the user is looking at.
    func openSessionForContainer(_ selection: SessionSelection, container: String) {
        guard let target = sessionTarget(selection), target.container != container else { return }
        if let existing = openSession(kind: selection, pod: target.pod, container: container) {
            selectSession(existing)
            return
        }
        switch selection {
        case .shell: openPodShell(container: container)
        case .logs(let id): switchLogContainer(id, name: container)
        }
    }

    /// Whether `container` already has a session of this kind on this pod, which the switch menu
    /// says out loud rather than silently opening a second one.
    func hasOpenSession(_ selection: SessionSelection, container: String) -> Bool {
        guard let target = sessionTarget(selection) else { return false }
        return openSession(kind: selection, pod: target.pod, container: container) != nil
    }
}

public extension AppActions {
    /// Where a session points, asked once for either kind — the deck's strip and meta row need the
    /// same four facts whether the session is a shell or a log tail.
    struct SessionTarget: Equatable, Sendable {
        public let context: ResolvedContext
        public let namespace: String
        public let pod: String
        public let container: String
    }

    func sessionTarget(_ selection: SessionSelection) -> SessionTarget? {
        switch selection {
        case .shell(let id):
            guard let session = store.execSessions.first(where: { $0.id == id }) else { return nil }
            return SessionTarget(
                context: session.target.context, namespace: session.target.namespace,
                pod: session.target.pod, container: session.target.container
            )
        case .logs(let id):
            guard let session = logSession(id) else { return nil }
            return SessionTarget(
                context: session.target.context, namespace: session.target.namespace,
                pod: session.target.pod, container: session.target.container.name
            )
        }
    }

}

extension AppActions {
    private func openSession(kind: SessionSelection, pod: String, container: String) -> SessionSelection? {
        store.openSessions.first { candidate in
            guard candidate.isLogs == kind.isLogs, let target = sessionTarget(candidate) else { return false }
            return target.pod == pod && target.container == container
        }
    }
}
