#if DEBUG
import AppKit
import KubixCore

/// One strip for both kinds of session: collapsing hides the bodies without ending anything, the
/// selection moves between sessions, and switching container reports an already-open container as
/// open rather than opening a second session against it.
@MainActor enum PodDeckValidation {
    static func check(_ fixture: PodBrowsingFixture, window: NSWindow, terminal: NSView) async throws -> String {
        let store = fixture.store
        let actions = fixture.actions
        let open = store.openSessions
        guard open.count == 2, open.allSatisfy({ !$0.isLogs }), store.selectedSession == open[1] else {
            throw Failure.assertion
        }
        // Two shells on one pod differ only by container, so the switch must say one is already open.
        guard let target = actions.sessionTarget(open[1]),
              actions.hasOpenSession(open[1], container: target.container),
              !actions.hasOpenSession(open[1], container: "debugger") else { throw Failure.assertion }
        actions.selectSession(open[0])
        guard store.selectedSession == open[0] else { throw Failure.assertion }
        actions.selectSession(open[1])

        let running = terminal.visibleRect.height
        actions.setDeckCollapsed(true)
        // A detached view keeps reporting its bounds, so leaving the window is what says it is gone.
        try await PodBrowsingValidation.until { terminal.window == nil }
        guard store.openSessions.count == 2, store.execSessions.allSatisfy({ !$0.isClosed }),
              fixture.surfaces.created.allSatisfy({ $0.freeCount == 0 }) else { throw Failure.assertion }
        actions.setDeckCollapsed(false)
        try await PodBrowsingValidation.until { terminal.window != nil && terminal.visibleRect.height >= running - 1 }
        guard store.execSessions.allSatisfy({ $0.state == .running }),
              fixture.surfaces.created.allSatisfy({ $0.freeCount == 0 }) else { throw Failure.assertion }
        return String(
            format: "collapse unmounts %.0fpt of live terminal with both sessions open, still running and "
                + "zero surfaces freed; restore remounts the same view; selection moves between sessions; "
                + "an open container reports as open",
            running
        )
    }

    private enum Failure: Error { case assertion }
}
#endif
