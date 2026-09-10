import AppKit
import GhosttyKit

/// Callbacks run synchronously inside the pinned binding/completion calls. Only the explicit
/// AppKit paste action opens this gate; OSC 52 reads never acquire a request or access the board.
final class GhosttyPasteRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = false
    private var request: UInt?
    private var confirmation: UInt?
    private var deniedRequests = 0
    var deniedCount: Int { lock.withLock { deniedRequests } }

    func begin() { lock.withLock { accepting = true; request = nil; confirmation = nil } }
    func read(_ state: UnsafeMutableRawPointer?) -> Bool {
        lock.withLock {
            guard accepting, request == nil, let state else { deniedRequests += 1; return false }
            request = UInt(bitPattern: state)
            return true
        }
    }
    func end() -> UnsafeMutableRawPointer? {
        lock.withLock { accepting = false; return request.flatMap(UnsafeMutableRawPointer.init(bitPattern:)) }
    }
    func confirm(_ state: UnsafeMutableRawPointer?, kind: ghostty_clipboard_request_e) {
        lock.withLock {
            guard kind == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let state, request == UInt(bitPattern: state) else { return }
            confirmation = UInt(bitPattern: state)
        }
    }
    func needsApproval(_ state: UnsafeMutableRawPointer) -> Bool {
        lock.withLock { confirmation == UInt(bitPattern: state) }
    }
}

struct PendingGhosttyPaste {
    let id = UUID()
    let request: UnsafeMutableRawPointer
    let text: String
    let alert: NSAlert
}

extension GhosttySurfaceView {
    @objc func paste(_ sender: Any?) {
        guard let surface, pendingPaste == nil, let text = clipboardText(), !text.isEmpty else { return }
        pasteRequest.begin()
        let action = "paste_from_clipboard"
        action.withCString { _ = ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
        guard let request = pasteRequest.end() else { return }
        text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, request, false) }
        guard pasteRequest.needsApproval(request) else { return }
        guard let window else {
            ghostty_surface_complete_clipboard_request(surface, "", request, false)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Paste potentially unsafe text?"
        alert.informativeText = "This paste may execute commands in the terminal. Paste only if you trust its contents."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Paste")
        let pending = PendingGhosttyPaste(request: request, text: text, alert: alert)
        let id = pending.id
        pendingPaste = pending
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.pendingPaste?.id == id else { return }
            self.finishPaste(approved: response == .alertSecondButtonReturn)
        }
    }

    func finishPaste(approved: Bool) {
        guard let pending = pendingPaste else { return }
        pendingPaste = nil
        // Empty unconfirmed completion cancels and frees the engine-owned request. It must happen
        // before surface_free; a delayed sheet callback can no longer touch this request.
        if let surface {
            (approved ? pending.text : "").withCString {
                ghostty_surface_complete_clipboard_request(surface, $0, pending.request, approved)
            }
        }
        if let parent = pending.alert.window.sheetParent {
            parent.endSheet(pending.alert.window, returnCode: .cancel)
        }
    }
}
