#if DEBUG
import AppKit
import GhosttyKit
import KubixCore

/// An opt-in fixed native smoke, not a cluster validation or a general control interface.
@MainActor enum PodBrowsingValidation {
    static let directory = ProcessInfo.processInfo.environment["KUBIX_POD_UI_SMOKE_DIRECTORY"]
    static var isEnabled: Bool { directory != nil }
    private static var didRun = false
    private static var stage = "startup"
    private static var evidence: [String: String] = [:]
    private static var children: [pid_t] = []

    static func run(_ fixture: PodBrowsingFixture) async {
        guard let directory, !didRun else { return }
        didRun = true
        do {
            try await check(fixture)
            evidence["result"] = "passed"
        } catch {
            evidence["result"] = "failed"
            evidence["failedStage"] = stage
            evidence["failure"] = String(describing: error)
            evidence["storeState"] = fixture.store.podTable.message
            evidence["storeRows"] = String(fixture.store.rows.count)
            evidence["nativeRows"] = String(NSApp.windows.compactMap { table(in: $0)?.numberOfRows }.first ?? -1)
            evidence["committedNamespace"] = fixture.store.selectedNamespace
            evidence["shellPhase"] = PodShellNativeValidation.phase
            evidence["pickerVisible"] = String(fixture.store.containerPicker != nil)
            evidence["shellDiagnostic"] = fixture.store.podShellDiagnostic ?? "none"
            evidence["shellRequests"] = String(await fixture.transport.requests.filter { $0.accept == "application/json" }.count)
            evidence["attachedSheet"] = String(NSApp.windows.contains { $0.attachedSheet != nil })
        }
        for view in fixture.surfaces.created {
            if let surface = view.surface {
                let pid = pid_t(ghostty_surface_foreground_pid(surface))
                if pid > 0, !children.contains(pid) { children.append(pid) }
            }
        }
        evidence["ownedChildPIDs"] = children.map(String.init).joined(separator: ",")
        await fixture.actions.shutdownAndWait()
        await fixture.authentication.finish()
        do {
            try await until { children.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
            guard fixture.surfaces.created.allSatisfy({ $0.freeCount == 1 }),
                  await fixture.transport.streams.allSatisfy(\.cancelled) else { throw Failure.assertion }
            evidence["cleanup"] = "actions joined; streams cancelled; \(children.count) local cat children reaped; \(fixture.surfaces.created.count) surfaces freed exactly once"
        } catch {
            evidence["result"] = "failed"
            evidence["cleanup"] = "failed"
        }
        evidence["scope"] = "synthetic only; production AppActions, WatchService and PodDetailsService; zero live config/auth/network/browser"
        evidence["appPID"] = String(ProcessInfo.processInfo.processIdentifier)
        let destination = URL(fileURLWithPath: directory).appendingPathComponent("result.json")
        if let data = try? JSONEncoder().encode(evidence) { try? data.write(to: destination, options: .atomic) }
        for window in NSApp.windows { window.endEditing(for: nil) }
        // Termination's async delegate must run after this SwiftUI task yields its main-actor job.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    private static func check(_ fixture: PodBrowsingFixture) async throws {
        let store = fixture.store
        try await until { NSApp.windows.contains { table(in: $0) != nil } }
        guard let window = NSApp.windows.first(where: { table(in: $0) != nil }), let table = table(in: window) else {
            throw Failure.assertion
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard store.connection == .idle, await fixture.transport.requests.isEmpty,
              store.configurationDiagnostics.contains(where: { $0.contains("proxy-url is unsupported") }),
              store.contexts.count == 2 else { throw Failure.assertion }
        evidence["initial"] = "idle; unsupported proxy diagnostic; blocked context excluded before auth; no automatic requests"

        stage = "namespace typing and submission"
        try await edit("team", placeholder: "Namespace", in: window)
        try await until { store.namespaceDraft == "team" }
        guard await fixture.transport.requests.isEmpty else { throw Failure.assertion }
        try submit(placeholder: "Namespace", in: window)
        try await until { await fixture.transport.requests.count == 2 }
        guard store.connection == .connecting, table.numberOfRows == 0, store.podTable.state == .connecting else { throw Failure.assertion }
        evidence["pagination"] = "native table empty/connecting during blocked second page, not a partial live list"
        try await until { store.connection == .live && table.numberOfRows == 2 }
        guard table.tableColumns.map(\.title) == ["Workload", "Count", "Flag"],
              (table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)?.stringValue == "zulu" else {
            throw Failure.assertion
        }
        evidence["rendering"] = "real NSTableView data-source cells render synthetic server-defined columns"
        try await checkTable(fixture, window: window, table: table)
        try await checkSessions(fixture, window: window, table: table)
        try await checkDraftsAndStates(fixture, window: window, table: table)
    }

    private static func checkTable(_ fixture: PodBrowsingFixture, window: NSWindow, table: NSTableView) async throws {
        let store = fixture.store
        let actions = fixture.actions
        stage = "native selection sort and headerless watch"
        table.sortDescriptors = [NSSortDescriptor(key: "1", ascending: true)]
        try await until {
            store.podSort?.column == 1 && (table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)?.stringValue == "alpha"
        }
        window.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await until { store.selectedPodUID == "uid-a" }
        guard let down = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125
        ) else { throw Failure.assertion }
        window.sendEvent(down)
        try await until { store.selectedPodUID == "uid-z" }
        table.sortDescriptors = [NSSortDescriptor(key: "1", ascending: false)]
        try await until { store.podSort?.column == 1 && table.selectedRow == 0 }
        await fixture.transport.modify()
        try await until {
            store.rows.contains { $0.id == "uid-z" && $0.cells.first == .string("aardvark") } && table.selectedRow == 1
        }
        guard store.selectedPodUID == "uid-z", table.tableColumns.count == 3 else { throw Failure.assertion }
        evidence["selection"] = "native arrow event updates UID; native sort moves selected row; headerless watch retains columns and UID"

        stage = "wide columns and native filter"
        actions.setPodWide(true)
        try await until { table.tableColumns.count == 5 }
        guard table.tableColumns[3].title == "Workload", table.tableColumns[4].title == "Custom" else { throw Failure.assertion }
        table.sortDescriptors = [NSSortDescriptor(key: "3", ascending: true)]
        try await until { store.podSort?.column == 3 }
        actions.setPodWide(false)
        try await until { table.tableColumns.count == 3 && table.sortDescriptors.isEmpty }
        try await edit("alpha", placeholder: "Filter visible columns", in: window)
        try await until { table.numberOfRows == 1 && store.selectedPodUID == nil }
        try await edit("missing", placeholder: "Filter visible columns", in: window)
        try await until { store.podTable.state == .filteredEmpty && table.numberOfRows == 0 }
        try await edit("", placeholder: "Filter visible columns", in: window)
        try await until { table.numberOfRows == 2 && store.selectedPodUID == nil }
        evidence["wideFilter"] = "5 dynamic columns including duplicate names; hidden sort reset; real TextField filtering clears invisible UID"

    }

    private static func checkSessions(_ fixture: PodBrowsingFixture, window: NSWindow, table: NSTableView) async throws {
        stage = "stable session deck and minimum window"
        let actions = fixture.actions
        let ids = try await PodShellNativeValidation.open(fixture, window: window, table: table)
        let first = ids[0]
        let second = ids[1]
        let targets = fixture.store.execSessions.map(\.target)
        evidence["rowShells"] = "native Return opens single regular; right-click menu targets other row; stale picker cancelled; real sheet default/confirmation; fresh plain-JSON GET per flow"
        try await until { fixture.surfaces.created.count == 2 && fixture.surfaces.created.allSatisfy { $0.surface != nil } }
        guard let firstView = actions.surface(for: first) as? GhosttySurfaceView,
              let secondView = actions.surface(for: second) as? GhosttySurfaceView else { throw Failure.assertion }
        let views = [firstView, secondView]
        children = views.map { pid_t(ghostty_surface_foreground_pid($0.surface)) }
        guard children.allSatisfy({ $0 > 0 }) else { throw Failure.assertion }
        actions.selectShell(first)
        window.makeFirstResponder(views[0])
        try TerminalSmokeTest.type("synthetic-terminal\n", in: window)
        try await until { TerminalSmokeTest.viewport(views[0]).contains("synthetic-terminal") }
        try actions.selectContext(named: "synthetic-second")
        actions.setPodFilter("alpha")
        actions.sortPods(.init(column: 0))
        actions.selectShell(second)
        stage = "default and minimum window layout"
        for size in [NSSize(width: 1050, height: 800), NSSize(width: 760, height: 600)] {
            window.setContentSize(size)
            try await Task.sleep(for: .milliseconds(150))
            window.contentView?.layoutSubtreeIfNeeded()
            if let namespace = field("Namespace", in: window) { namespace.scrollToVisible(namespace.bounds) }
            window.displayIfNeeded()
            evidence["layout-\(Int(size.width))"] = "table \(table.enclosingScrollView?.visibleRect.height ?? 0); "
                + "terminal \(views[1].visibleRect.width)x\(views[1].visibleRect.height); namespace \(field("Namespace", in: window)?.visibleRect.height ?? 0)"
            guard table.enclosingScrollView?.visibleRect.height ?? 0 >= 70,
                  views[1].visibleRect.height >= 60, views[1].visibleRect.width >= 700,
                  field("Namespace", in: window)?.visibleRect.height ?? 0 > 0 else { throw Failure.assertion }
        }
        stage = "session target identity and lifetime"
        guard fixture.store.execSessions.map(\.target) == targets,
              actions.surface(for: first) === views[0], actions.surface(for: second) === views[1],
              views.allSatisfy({ $0.freeCount == 0 }) else { throw Failure.assertion }
        evidence["sessionsLayout"] = "two real Ghostty/local-cat surfaces; keyboard echo; stable targets/identity, zero frees through context/filter/sort; "
            + "table and terminal usable at 1050x800 and 760x600"
        actions.setPodFilter("")
    }

    private static func checkDraftsAndStates(_ fixture: PodBrowsingFixture, window: NSWindow, table: NSTableView) async throws {
        let store = fixture.store
        let actions = fixture.actions
        stage = "intentional namespace commits and errors"
        try await until { store.connection == .live }
        let count = await fixture.transport.requests.count
        try await edit("known", placeholder: "Namespace", in: window)
        try await until { store.namespaceDraft == "known" }
        guard store.selectedNamespace == "other", await fixture.transport.requests.count == count else { throw Failure.assertion }
        try submit(placeholder: "Namespace", in: window)
        try await until { store.connection == .live && store.selectedNamespace == "known" }
        guard store.namespaces == ["other", "known"] else { throw Failure.assertion }
        try await edit("bad/input", placeholder: "Namespace", in: window)
        try submit(placeholder: "Namespace", in: window)
        try await until { store.namespaceDiagnostic != nil }
        guard store.selectedNamespace == "known" else { throw Failure.assertion }
        try actions.selectNamespace("empty")
        try await until { store.podTable.state == .empty && table.numberOfRows == 0 }
        try actions.selectNamespace("forbidden")
        try await until { store.podTable.state == .failed && store.podTable.message.contains("Forbidden: pods") }
        evidence["states"] = "native typing does not commit; Return commits once; invalid draft rejected; suggestions remembered per context; empty and forbidden states shown inline"

        stage = "auth progress settings and configured retry"
        guard let context = store.selectedContext else { throw Failure.assertion }
        try await fixture.authentication.showProgress(for: context, failed: false)
        try await until { store.visibleAuthenticationSessions.contains { $0.state == .waitingForBrowser } }
        actions.setShowingSettings(true)
        try await until { window.attachedSheet != nil }
        actions.setShowingSettings(false)
        try await until { window.attachedSheet == nil }
        try await fixture.authentication.showProgress(for: context, failed: true)
        try await until { store.visibleAuthenticationSessions.contains { $0.state == .failed } }
        guard let failed = store.visibleAuthenticationSessions.first(where: { $0.state == .failed }) else { throw Failure.assertion }
        try await actions.retryAuthentication(operationID: failed.id)
        guard await fixture.authentication.retryCount == 1, store.podTable.state == .failed else { throw Failure.assertion }
        evidence["auth"] = "synthetic progress and failed-plugin Retry retained; actual settings sheet opens/dismisses; successful auth does not retry forbidden pods"
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func table(in window: NSWindow) -> NSTableView? {
        window.contentView.flatMap { descendants($0).compactMap { $0 as? NSTableView }.first { $0.identifier?.rawValue == "pod-table" } }
    }
    private static func field(_ placeholder: String, in window: NSWindow) -> NSTextField? {
        window.contentView.flatMap { descendants($0).compactMap { $0 as? NSTextField }.first { $0.placeholderString == placeholder } }
    }
    private static func edit(_ value: String, placeholder: String, in window: NSWindow) async throws {
        guard let field = field(placeholder, in: window) else { throw Failure.assertion }
        field.selectText(nil)
        // AppKit installs/synchronizes its shared field editor on the next run-loop turn.
        try await Task.sleep(for: .milliseconds(30))
        guard let editor = window.fieldEditor(false, for: field) as? NSTextView else { throw Failure.assertion }
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        editor.setSelectedRange(range)
        editor.insertText(value, replacementRange: range)
        try await until { field.stringValue == value && editor.string == value }
    }
    private static func submit(placeholder: String, in window: NSWindow) throws {
        guard let field = field(placeholder, in: window),
              let editor = window.fieldEditor(false, for: field) as? NSTextView else { throw Failure.assertion }
        editor.doCommand(by: NSSelectorFromString("insertNewline:"))
    }
    private static func until(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private enum Failure: Error { case assertion, timeout }
}
#endif
