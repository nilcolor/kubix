#if DEBUG
import AppKit
import GhosttyKit
import KubixCore
import Vision

/// Opt-in, fixed native integration check. No socket, listener, arbitrary command, or control API.
/// The launcher supplies an isolated shell home and startup fixtures; ordinary launches never run it.
@MainActor
enum TerminalSmokeTest {
    private static var didRun = false
    private static let directory = ProcessInfo.processInfo.environment["KUBIX_TERMINAL_SMOKE_DIRECTORY"]
    private static var stage = "startup"
    private static var evidence: [String: String] = [:]

    static var configuration: TerminalConfiguration {
        guard let directory, let startup = ProcessInfo.processInfo.environment["KUBIX_TERMINAL_SMOKE_STARTUP"] else {
            return .loginShell
        }
        return try! TerminalConfiguration(environment: [
            "HOME": directory + "/home", "ZDOTDIR": startup, "KUBIX_SMOKE_VALUE": "value with spaces=OK",
        ], workingDirectory: directory)
    }

    static func run(_ session: LocalTerminalSession) async {
        guard let directory, !didRun else { return }
        didRun = true
        do {
            try await check(session, directory: URL(fileURLWithPath: directory, isDirectory: true))
            stage = "command wait policy and window close"
            try await TerminalSmokeLifecycle.check(configuration: configuration)
            evidence["additionalLifecycle"] = "command wait=false/true, initial_input, live window close, pre-attach close passed"
            evidence["result"] = "passed"
        } catch {
            evidence["result"] = "failed"
            evidence["failedStage"] = stage
            evidence["error"] = String(describing: error)
            if let view = session.view {
                try? viewport(view).write(toFile: directory + "/failed-viewport.txt", atomically: true, encoding: .utf8)
                evidence["focused"] = String(view.window?.firstResponder === view)
            }
            session.close()
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("result.json")
        if let data = try? JSONEncoder().encode(evidence) { try? data.write(to: url, options: .atomic) }
        NSApp.terminate(nil)
    }

    private static func check(_ session: LocalTerminalSession, directory: URL) async throws {
        try await until { session.view?.surface != nil && session.view?.window != nil }
        guard let view = session.view, let window = view.window else { throw SmokeError.failed }
        guard view.configuration.command == nil, view.configuration.initialInput == nil else { throw SmokeError.failed }
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(view)
        try await until { viewport(view).contains("kubix-smoke>") }
        let child = ghostty_surface_foreground_pid(view.surface)
        guard child > 0 else { throw SmokeError.failed }
        evidence["shellPID"] = String(child)
        evidence["command"] = "nil (login shell)"

        stage = "keyboard and login shell"
        try type("printf '\\033[2J\\033[H'; printf 'KUBIX_%s\\n' INPUT; printf 'LOGIN_%s\\n' $options[login]\n", in: window)
        try await until { viewport(view).contains("KUBIX_INPUT") && viewport(view).contains("LOGIN_on") }
        try type("[[ \"$KUBIX_SMOKE_VALUE\" == 'value with spaces=OK' && \"$PWD\" == \"$KUBIX_TERMINAL_SMOKE_DIRECTORY\" ]] && printf 'CONFIG_%s\\n' OK\n", in: window)
        try await until { viewport(view).contains("CONFIG_OK") }
        evidence["input"] = "NSEvent keyDown/keyUp through NSWindow; executed printf output observed"
        evidence["configuration"] = "login option on; synthetic per-surface environment and working directory verified"
        try type("printf '\\033]0;Kubix Smoke\\007'\n", in: window)
        try await until { window.title == "Kubix Smoke" }
        evidence["titleCallback"] = "OSC title copied and applied on main actor"

        stage = "initial rendering"
        try await capture(view, marker: "KUBIXINPUT", to: directory.appendingPathComponent("initial.png"))
        let initial = ghostty_surface_size(view.surface)
        guard initial.columns > 0, initial.rows > 0 else { throw SmokeError.failed }
        evidence["initialGrid"] = "\(initial.columns)x\(initial.rows)"

        stage = "resize"
        window.setContentSize(NSSize(width: 720, height: 440))
        try await until {
            let size = ghostty_surface_size(view.surface)
            return size.columns != initial.columns && size.rows != initial.rows
        }
        let resized = ghostty_surface_size(view.surface)
        let expected = "\(resized.rows) \(resized.columns)"
        try type("printf 'SIZE_%s\\n' \"$(stty size)\"; printf 'KUBIX_%s\\n' RESIZED\n", in: window)
        try await until { viewport(view).contains("SIZE_" + expected) && viewport(view).contains("KUBIX_RESIZED") }
        evidence["resizedGrid"] = "\(resized.columns)x\(resized.rows)"
        evidence["ptyResize"] = "stty size = " + expected
        stage = "resized rendering"
        try await capture(view, marker: "KUBIXRESIZED", to: directory.appendingPathComponent("resized.png"))

        try await checkTeardown(session, view: view, window: window, child: child)
    }

    private static func checkTeardown(
        _ session: LocalTerminalSession, view: GhosttySurfaceView, window: NSWindow, child: UInt64
    ) async throws {
        stage = "representable dismantle"
        TerminalView.dismantleNSView(view, coordinator: ())
        guard view.surface != nil, view.freeCount == 0 else { throw SmokeError.failed }
        evidence["dismantle"] = "live surface preserved, zero frees"

        stage = "shell exit and teardown"
        try type("exit\n", in: window)
        try await until { session.isClosed }
        session.close()
        view.teardown()
        try await until { kill(pid_t(child), 0) == -1 && errno == ESRCH }
        guard view.surface == nil, view.isDestroyed, view.freeCount == 1 else { throw SmokeError.failed }
        view.setFrameSize(NSSize(width: 800, height: 500))
        view.render()
        view.requestClose()
        guard view.surface == nil, view.freeCount == 1 else { throw SmokeError.failed }
        evidence["teardown"] = "shell exited/reaped; exactly one free; repeated close, resize, draw cannot resurrect"
    }

    private enum SmokeError: Error { case failed, timeout, missingWindow, markerNotRendered }

    static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SmokeError.timeout }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func viewport(_ view: GhosttySurfaceView) -> String {
        guard let surface = view.surface else { return "" }
        var selection = ghostty_selection_s()
        selection.top_left = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        selection.bottom_right = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    static func type(_ text: String, in window: NSWindow) throws {
        guard window.firstResponder is GhosttySurfaceView else { throw SmokeError.failed }
        let keys: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
            "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "\n": 36, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, "`": 50, " ": 49,
        ]
        let shifted: [Character: Character] = ["_": "-", "$": "4", "%": "5", "&": "7", "(": "9", ")": "0", "\"": "'", ":": ";"]
        for character in text {
            let lowercase = Character(String(character).lowercased())
            let base = shifted[character] ?? lowercase
            guard let code = keys[base] else { throw SmokeError.failed }
            let flags: NSEvent.ModifierFlags = base != character ? [.shift] : []
            let characters = character == "\n" ? "\r" : String(character)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: String(base), isARepeat: false, keyCode: code
                ) else { throw SmokeError.failed }
                window.sendEvent(event)
            }
        }
    }

    private static func capture(_ view: GhosttySurfaceView, marker: String, to url: URL) async throws {
        try await Task.sleep(for: .milliseconds(500))
        guard view.window?.occlusionState.contains(.visible) == true, !view.isHidden else {
            throw SmokeError.missingWindow
        }
        let image = try TerminalSmokeImage.capture(view)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SmokeError.failed }
        try png.write(to: url)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
        let normalized = recognized.uppercased().filter { $0.isLetter || $0.isNumber }
        guard normalized.contains(marker) else { throw SmokeError.markerNotRendered }
        evidence[url.deletingPathExtension().lastPathComponent + "Rendering"] = "visible window's Metal IOSurface pixels + Vision OCR: " + marker
    }
}
#endif
