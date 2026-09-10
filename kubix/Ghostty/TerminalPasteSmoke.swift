#if DEBUG
import AppKit
import GhosttyKit
import KubixCore

@MainActor
enum TerminalPasteSmoke {
    private enum Failure: Error { case assertion }

    static func check(configuration: TerminalConfiguration) async throws {
        let config = try TerminalConfiguration(
            command: "/bin/sh -c 'printf \"\\033]52;c;?\\007\"; exec /bin/cat'",
            environment: Dictionary(uniqueKeysWithValues: configuration.environment.map { ($0.key, $0.value) }),
            workingDirectory: configuration.workingDirectory
        )
        let session = LocalTerminalSession(configuration: config)
        guard let view = session.view else { throw Failure.assertion }
        let window = host(view)
        var clipboard = "SAFE_PASTE"
        var reads = 0
        view.clipboardText = { reads += 1; return clipboard }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        defer { session.close(); window.close() }
        try await TerminalSmokeTest.until { view.surface != nil && view.pasteRequest.deniedCount > 0 }
        let child = ghostty_surface_foreground_pid(view.surface)
        guard child > 0, reads == 0 else { throw Failure.assertion }
        try TerminalSmokeTest.type("KEYBOARD\n", in: window)
        view.insertText("IME", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await TerminalSmokeTest.until { TerminalSmokeTest.viewport(view).contains("IME") }
        try sendPaste(to: view, window: window)
        try await TerminalSmokeTest.until { TerminalSmokeTest.viewport(view).contains("SAFE_PASTE") }
        guard view.pendingPaste == nil, reads == 1 else { throw Failure.assertion }
        try TerminalSmokeTest.type("\n", in: window)
        clipboard = "UNAPPROVED\nSECOND_LINE\n"
        try sendPaste(to: view, window: window)
        try await TerminalSmokeTest.until { view.pendingPaste != nil && window.attachedSheet != nil }
        try await Task.sleep(for: .milliseconds(100))
        guard !TerminalSmokeTest.viewport(view).contains("UNAPPROVED"), let pending = view.pendingPaste else { throw Failure.assertion }
        window.endSheet(pending.alert.window, returnCode: .alertFirstButtonReturn)
        try await TerminalSmokeTest.until { view.pendingPaste == nil && window.attachedSheet == nil }
        guard !TerminalSmokeTest.viewport(view).contains("UNAPPROVED") else { throw Failure.assertion }
        window.makeFirstResponder(view)
        clipboard = "APPROVED\nAFTER_APPROVAL\n"
        try sendPaste(to: view, window: window)
        try await TerminalSmokeTest.until { view.pendingPaste != nil && window.attachedSheet != nil }
        guard !TerminalSmokeTest.viewport(view).contains("AFTER_APPROVAL"), let approval = view.pendingPaste else { throw Failure.assertion }
        window.endSheet(approval.alert.window, returnCode: .alertSecondButtonReturn)
        try await TerminalSmokeTest.until { TerminalSmokeTest.viewport(view).contains("AFTER_APPROVAL") && view.pendingPaste == nil }
        window.makeFirstResponder(view)
        clipboard = "DESTROY_PENDING\n"
        try sendPaste(to: view, window: window)
        try await TerminalSmokeTest.until { view.pendingPaste != nil && window.attachedSheet != nil }
        view.teardown()
        try await TerminalSmokeTest.until { window.attachedSheet == nil && kill(pid_t(child), 0) == -1 && errno == ESRCH }
        view.paste(nil)
        view.teardown()
        guard view.freeCount == 1, view.pendingPaste == nil, reads == 4 else { throw Failure.assertion }
        try await checkBracketed(configuration: configuration)
    }

    private static func sendPaste(to view: GhosttySurfaceView, window: NSWindow) throws {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9
        ), view.performKeyEquivalent(with: event) else { throw Failure.assertion }
    }

    private static func host(_ view: GhosttySurfaceView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 180, y: 180, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    private static func checkBracketed(configuration: TerminalConfiguration) async throws {
        let config = try TerminalConfiguration(
            command: "/bin/sh -c 'printf \"\\033[?2004hBRACKET_READY\\n\"; exec /bin/cat'",
            environment: Dictionary(uniqueKeysWithValues: configuration.environment.map { ($0.key, $0.value) }),
            workingDirectory: configuration.workingDirectory
        )
        let session = LocalTerminalSession(configuration: config)
        guard let view = session.view else { throw Failure.assertion }
        let window = host(view)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        defer { session.close(); window.close() }
        try await TerminalSmokeTest.until { TerminalSmokeTest.viewport(view).contains("BRACKET_READY") }
        let child = ghostty_surface_foreground_pid(view.surface)
        guard child > 0 else { throw Failure.assertion }
        view.clipboardText = { "BRACKETED_SAFE\nNEXT_SAFE\n" }
        try sendPaste(to: view, window: window)
        try await TerminalSmokeTest.until { TerminalSmokeTest.viewport(view).contains("NEXT_SAFE") }
        guard view.pendingPaste == nil else { throw Failure.assertion }
        view.clipboardText = { "ESCAPE_BRACKET\u{1b}[201~\n" }
        try sendPaste(to: view, window: window)
        try await TerminalSmokeTest.until { view.pendingPaste != nil }
        guard !TerminalSmokeTest.viewport(view).contains("ESCAPE_BRACKET") else { throw Failure.assertion }
        session.close()
        try await TerminalSmokeTest.until { window.attachedSheet == nil && kill(pid_t(child), 0) == -1 && errno == ESRCH }
        guard view.freeCount == 1, view.pendingPaste == nil else { throw Failure.assertion }
    }
}
#endif
