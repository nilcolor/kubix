// Bridge architecture adapted from thdxg/macterm (MIT), via agterm.
// Copyright (c) 2026 Macterm. See Resources/ThirdPartyNotices.txt.

import AppKit
import GhosttyKit

@MainActor
final class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private(set) var failure: String?
    private var sessions: [UUID: LocalTerminalSession] = [:]

    private init() {
        do {
            try GhosttyResources.configure()
        } catch {
            failure = "Bundled Ghostty resources or terminfo are missing. Run make prep and make build."
            return
        }
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS,
              let config = ghostty_config_new() else {
            failure = "Unable to initialize the terminal engine."
            return
        }
        // Deliberately do not load another terminal app's user configuration or CLI arguments.
        ghostty_config_finalize(config)
        var runtime = ghostty_runtime_config_s()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in GhosttyCallbacks.wakeup() }
        runtime.action_cb = { _, target, action in GhosttyCallbacks.action(target: target, action: action) }
        // AppKit Copy/Paste operates on the main actor. Terminal-initiated clipboard reads are denied.
        runtime.read_clipboard_cb = { _, _, _ in false }
        runtime.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtime.write_clipboard_cb = { _, _, content, count, confirm in
            GhosttyCallbacks.writeClipboard(content, count: count, requiresConfirmation: confirm)
        }
        runtime.close_surface_cb = { userdata, _ in GhosttyCallbacks.close(userdata) }
        guard let app = ghostty_app_new(&runtime, config) else {
            ghostty_config_free(config)
            failure = "Unable to create the terminal engine."
            return
        }
        self.config = config
        self.app = app
    }

    func register(_ session: LocalTerminalSession) {
        sessions[session.id] = session
    }

    func unregister(_ id: UUID) {
        sessions.removeValue(forKey: id)
    }

    func tick() {
        if let app { ghostty_app_tick(app) }
    }

    func setFocus(_ focused: Bool) {
        if let app { ghostty_app_set_focus(app, focused) }
    }

    func shutdown() {
        for session in Array(sessions.values) { session.close() }
        if let app {
            self.app = nil
            ghostty_app_free(app)
        }
        if let config {
            self.config = nil
            ghostty_config_free(config)
        }
    }
}

final class TerminalAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidBecomeActive(_ notification: Notification) { GhosttyApp.shared.setFocus(true) }
    func applicationDidResignActive(_ notification: Notification) { GhosttyApp.shared.setFocus(false) }
    func applicationWillTerminate(_ notification: Notification) { GhosttyApp.shared.shutdown() }
}
