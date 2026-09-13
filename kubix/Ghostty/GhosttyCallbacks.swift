// Bridge architecture adapted from thdxg/macterm (MIT).
// Copyright (c) 2026 Macterm. See Resources/ThirdPartyNotices.txt.

import AppKit
import GhosttyKit

/// No actor-isolated state is accessed synchronously at the C boundary. The session retains userdata
/// until surface_free has stopped all IO/rendering; queued closures retain the view and check teardown.
enum GhosttyCallbacks {
    static func wakeup() {
        DispatchQueue.main.async { GhosttyApp.shared.tick() }
    }

    static func action(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let view = view(ghostty_surface_userdata(surface)) else { return false }
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let pointer = action.action.set_title.title else { return false }
            let title = String(cString: pointer)
            DispatchQueue.main.async { view.applyTitle(title) }
        case GHOSTTY_ACTION_RENDER:
            DispatchQueue.main.async { view.render() }
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // The pinned engine forces wait-after-command for an explicit command, even if the C
            // option is false. Consume this action to implement immediate close; leave true to Ghostty.
            // Immutable creation policy is safe to read here, unlike the surface handle.
            guard !view.configuration.waitAfterCommand else { return false }
            DispatchQueue.main.async { view.requestClose() }
        default:
            return false
        }
        return true
    }

    static func close(_ userdata: UnsafeMutableRawPointer?) {
        guard let view = view(userdata) else { return }
        DispatchQueue.main.async { view.requestClose() }
    }

    static func readClipboard(_ userdata: UnsafeMutableRawPointer?, state: UnsafeMutableRawPointer?) -> Bool {
        view(userdata)?.pasteRequest.read(state) ?? false
    }

    static func confirmClipboard(
        _ userdata: UnsafeMutableRawPointer?, state: UnsafeMutableRawPointer?, kind: ghostty_clipboard_request_e
    ) {
        view(userdata)?.pasteRequest.confirm(state, kind: kind)
    }

    static func writeClipboard(
        _ content: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int,
        requiresConfirmation: Bool
    ) {
        // Do not silently authorize OSC 52 writes that require consent.
        guard !requiresConfirmation, let content, count > 0 else { return }
        for item in UnsafeBufferPointer(start: content, count: count) {
            guard let mime = item.mime, String(cString: mime) == "text/plain", let data = item.data else { continue }
            let text = String(cString: data)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return
        }
    }

    private static func view(_ userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }
}
