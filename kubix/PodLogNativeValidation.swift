#if DEBUG
import AppKit
import KubixCore

@MainActor enum PodLogNativeValidation {
    static func check(_ fixture: PodBrowsingFixture, window: NSWindow, table: NSTableView) async throws -> String {
        let actions = fixture.actions
        let shells = fixture.store.execSessions
        let views = shells.compactMap { actions.surface(for: $0.id) as? GhosttySurfaceView }
        try openMenu(table: table, window: window)
        try await PodBrowsingValidation.until { fixture.store.logSessions.first?.buffer.count == 401 }
        guard let session = fixture.store.logSessions.first else { throw Failure.assertion }
        try await PodBrowsingValidation.until { logTable(session.id, in: window)?.numberOfRows == 401 }
        guard let logTable = logTable(session.id, in: window), let scroll = logTable.enclosingScrollView else { throw Failure.assertion }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await PodBrowsingValidation.until { !session.autoscroll }
        let first = await fixture.transport.logStreams[0]
        first.yield(Data("synthetic fixture extra\n".utf8))
        try await PodBrowsingValidation.until { session.buffer.count == 402 && logTable.numberOfRows == 402 }
        guard scroll.contentView.bounds.minY < 5 else { throw Failure.assertion }
        try await PodBrowsingValidation.edit("line 399", placeholder: "Filter log lines", in: window)
        try await PodBrowsingValidation.until { session.filter == "line 399" && logTable.numberOfRows == 2 }
        try await PodBrowsingValidation.edit("", placeholder: "Filter log lines", in: window)
        first.fail()
        try await PodBrowsingValidation.until { session.state == .interrupted(.transport) }
        let before = session.buffer.count
        actions.resumeLog(session.id)
        try await PodBrowsingValidation.until { session.segment == 2 && session.state == .following && session.buffer.count > before }
        guard session.buffer.lines.filter(\.isBoundary).count == 2 else { throw Failure.assertion }
        actions.pauseLog(session.id)
        try await PodBrowsingValidation.until { await fixture.transport.logStreams.allSatisfy(\.cancelled) }
        actions.switchLogContainer(session.id, name: "setup")
        try await PodBrowsingValidation.until { fixture.store.logSessions.count == 2 && fixture.store.logSessions.last?.state == .following }
        guard let switched = fixture.store.logSessions.last, switched.target.container.kind == .initContainer,
              switched.id != session.id, session.target.container.kind == .regular,
              views.allSatisfy({ $0.freeCount == 0 }), fixture.store.execSessions.map(\.target) == shells.map(\.target) else { throw Failure.assertion }
        for (index, shell) in shells.enumerated() {
            guard actions.surface(for: shell.id) === views[index] else { throw Failure.assertion }
        }
        actions.closeLog(session.id)
        actions.closeLog(switched.id)
        guard let shell = shells.first else { throw Failure.assertion }
        actions.selectShell(shell.id)
        try await PodBrowsingValidation.until { await fixture.transport.logStreams.allSatisfy(\.cancelled) }
        guard await fixture.transport.logRequests.count == 3,
              await fixture.transport.logStreams.allSatisfy(\.cancelled),
              views.allSatisfy({ $0.freeCount == 0 }) else { throw Failure.assertion }
        return "native Logs menu; real bounded virtual table and filter field; scroll-up disables autoscroll; interruption/Resume boundary; "
            + "fresh init-container switch distinct UUID; close joins streams; two existing exec UUIDs/targets/surfaces preserved with zero frees; "
            + "synthetic only; counts/state evidence, no log text or screenshots"
    }

    private static func openMenu(table: NSTableView, window: NSWindow) throws {
        guard let native = table as? PodNativeTable else { throw Failure.assertion }
        let point = table.convert(NSPoint(x: 20, y: table.rect(ofRow: 0).midY), to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ), let menu = native.menu(for: event), let item = menu.items.first(where: { $0.title == "Logs" }),
              let selector = item.action else { throw Failure.assertion }
        NSApp.sendAction(selector, to: item.target, from: item)
    }

    private static func logTable(_ id: UUID, in window: NSWindow) -> NSTableView? {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        return window.contentView.flatMap {
            descendants($0).compactMap { $0 as? NSTableView }.first { $0.identifier?.rawValue == "log-lines-\(id)" }
        }
    }

    private enum Failure: Error { case assertion }
}
#endif
