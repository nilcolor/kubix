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

    /// Focus the subject's session for `container` if one is open, and otherwise open it. Either way
    /// the new session is validated the way a first one is: a log tail revalidates through its own
    /// scope, and a shell reruns the selected row's details, so neither can reach an object that is
    /// no longer the one the user is looking at.
    func openSessionForContainer(_ selection: SessionSelection, container: String) {
        guard let target = sessionTarget(selection), target.container != container else { return }
        if let existing = openSession(kind: selection, target: target, container: container) {
            selectSession(existing)
            return
        }
        switch selection {
        case .shell: openPodShell(container: container)
        case .logs(let id): switchLogContainer(id, name: container)
        }
    }

    /// Whether `container` already has a session of this kind on this subject, which the switch menu
    /// says out loud rather than silently opening a second one.
    func hasOpenSession(_ selection: SessionSelection, container: String) -> Bool {
        guard let target = sessionTarget(selection) else { return false }
        return openSession(kind: selection, target: target, container: container) != nil
    }
}

public extension AppActions {
    /// Where a session points, asked once for either kind — the deck's strip and meta row need the
    /// same facts whether the session is a shell or a log tail. `name` and `kind` say what the tab
    /// follows: a pod for a shell and for a pod's logs, a deployment for an aggregated tail. No UID
    /// here, deliberately — a shell's `ExecTarget` has none, and this is what the deck displays and
    /// what tells two tabs apart, not what a session is bound to.
    struct SessionTarget: Equatable, Sendable {
        public let context: ResolvedContext
        public let namespace: String
        public let name: String
        public let kind: ResourceKind
        public let container: String

        /// What the deck's tab and breadcrumb read: a pod's name, or `deploy/<name>`.
        public var display: String { kind == .pods ? name : "deploy/" + name }
    }

    func sessionTarget(_ selection: SessionSelection) -> SessionTarget? {
        switch selection {
        case .shell(let id):
            guard let session = store.execSessions.first(where: { $0.id == id }) else { return nil }
            return SessionTarget(
                context: session.target.context, namespace: session.target.namespace,
                name: session.target.pod, kind: .pods, container: session.target.container
            )
        case .logs(let id):
            guard let session = logSession(id) else { return nil }
            let subject = session.scope.subject
            return SessionTarget(
                context: session.scope.context, namespace: session.scope.namespace,
                name: subject.name, kind: subject.kind, container: session.scope.container.name
            )
        }
    }
}

extension AppActions {
    private func openSession(kind: SessionSelection, target: SessionTarget, container: String) -> SessionSelection? {
        store.openSessions.first { candidate in
            guard candidate.isLogs == kind.isLogs, let other = sessionTarget(candidate) else { return false }
            return other.name == target.name && other.kind == target.kind && other.container == container
        }
    }
}
