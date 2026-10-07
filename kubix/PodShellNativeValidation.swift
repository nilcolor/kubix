#if DEBUG
import AppKit
import KubixCore

@MainActor enum PodShellNativeValidation {
    private(set) static var phase = "Return"
    static func open(_ fixture: PodBrowsingFixture, window: NSWindow, table: NSTableView) async throws -> [UUID] {
        let actions = fixture.actions
        let store = fixture.store
        guard let alpha = store.listTable.rows.firstIndex(where: { $0.id == "uid-a" }) else { throw Failure.assertion }
        window.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: alpha), byExtendingSelection: false)
        try await until { store.selectedRowUID == "uid-a" }
        guard let enter = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ) else { throw Failure.assertion }
        window.sendEvent(enter)
        try await until { store.execSessions.first?.state == .running }
        guard store.execSessions[0].target.pod == "alpha", store.execSessions[0].target.container == "web" else { throw Failure.assertion }
        phase = "first context menu picker"
        try menu(uid: "uid-z", store: store, window: window, table: table)
        // The choice is a menu hanging off its button now, not a sheet: it must not take the window
        // modal, and it must actually be on screen rather than only in the store.
        try await until { store.containerPicker != nil && menuWindow() != nil }
        guard window.attachedSheet == nil else { throw Failure.assertion }
        let stale = try picker(store)
        phase = "cancel stale picker"
        actions.selectRow(uid: "uid-a")
        actions.confirmPodShell(selectionID: stale.id, container: "sidecar")
        try await until { store.containerPicker == nil && menuWindow() == nil }
        guard store.execSessions.count == 1 else { throw Failure.assertion }
        phase = "second context menu picker"
        try menu(uid: "uid-z", store: store, window: window, table: table)
        try await until { store.containerPicker != nil && menuWindow() != nil }
        let pending = try picker(store)
        phase = "rendered container menu"
        guard window.attachedSheet == nil, let presented = menuWindow(), presented.isVisible else {
            throw Failure.assertion
        }
        // What the menu draws, asserted where it is decided: the pod's own roles and states.
        guard pending.purpose == .shell, pending.items.map(\.role) == ["Container", "Default container"],
              pending.items.map(\.state) == ["Running", "Running"] else { throw Failure.assertion }
        actions.confirmPodShell(selectionID: pending.id, container: "sidecar")
        phase = "confirmed second session"
        try await until { store.execSessions.count == 2 && store.execSessions[1].state == .running && menuWindow() == nil }
        guard store.execSessions[1].target.pod == "zulu", store.execSessions[1].target.container == "sidecar" else { throw Failure.assertion }
        // The unnamespaced /version probe shares this Accept header; only pod details are counted here.
        let requests = await fixture.transport.requests.filter { $0.accept == "application/json" && $0.path.first == "api" }
        guard requests.count == 3, requests.map({ $0.path.last }) == ["alpha", "zulu", "zulu"] else { throw Failure.assertion }
        return store.execSessions.map(\.id)
    }

    /// A SwiftUI popover is its own window, so its presence is what says the menu is open. Its
    /// buttons are not AppKit controls, which is why the choice itself is made through AppActions.
    private static func menuWindow() -> NSWindow? {
        NSApp.windows.first { $0.className.contains("Popover") && $0.isVisible }
    }

    private static func picker(_ store: AppStore) throws -> ContainerPickerPresentation {
        guard let picker = store.containerPicker, picker.containers == ["web", "sidecar"],
              picker.defaultContainer == "sidecar", picker.pod == "zulu" else { throw Failure.assertion }
        return picker
    }

    private static func menu(uid: String, store: AppStore, window: NSWindow, table: NSTableView) throws {
        guard let row = store.listTable.rows.firstIndex(where: { $0.id == uid }) else { throw Failure.assertion }
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ), let menu = table.menu(for: event), menu.items.map(\.title) == ["Shell", "Logs"] else { throw Failure.assertion }
        menu.performActionForItem(at: 0)
    }

    private static func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure.assertion }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private enum Failure: Error { case assertion }
}
#endif
