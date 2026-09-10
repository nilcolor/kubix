// Bridge architecture adapted from thdxg/macterm (MIT), via agterm.
// Copyright (c) 2026 Macterm. See Resources/ThirdPartyNotices.txt.

import AppKit
import GhosttyKit

extension GhosttySurfaceView {
    override func keyDown(with event: NSEvent) {
        guard let surface else { return }
        var key = keyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
        if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.command) {
            let text = event.charactersIgnoringModifiers ?? ""
            text.withCString {
                key.text = $0
                _ = ghostty_surface_key(surface, key)
            }
            return
        }
        let wasMarked = hasMarkedText()
        let translated = translationEvent(event)
        interpretingKey = true
        committedText = []
        interpretKeyEvents([translated])
        interpretingKey = false
        key.consumed_mods = Self.modifiers(translated.modifierFlags.intersection([.shift, .option, .capsLock]))
        key.composing = wasMarked || hasMarkedText()
        if !committedText.isEmpty {
            key.composing = false
            for text in committedText {
                text.withCString {
                    key.text = $0
                    _ = ghostty_surface_key(surface, key)
                }
            }
        } else if !hasMarkedText() {
            key.text = nil
            key.consumed_mods = GHOSTTY_MODS_NONE
            _ = ghostty_surface_key(surface, key)
        }
    }

    override func keyUp(with event: NSEvent) {
        if let surface { _ = ghostty_surface_key(surface, keyEvent(event, action: GHOSTTY_ACTION_RELEASE)) }
    }

    override func flagsChanged(with event: NSEvent) {
        let flag: NSEvent.ModifierFlags
        switch event.keyCode {
        case 56, 60: flag = .shift
        case 59, 62: flag = .control
        case 58, 61: flag = .option
        case 55, 54: flag = .command
        case 57: flag = .capsLock
        default: return
        }
        if let surface {
            let action = event.modifierFlags.contains(flag) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
            _ = ghostty_surface_key(surface, keyEvent(event, action: action))
        }
    }

    override func doCommand(by selector: Selector) {}

    private func keyEvent(_ event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = Self.modifiers(event.modifierFlags)
        key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        return key
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var bits = GHOSTTY_MODS_NONE.rawValue
        for (flag, bit) in [
            (NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT),
            (.control, GHOSTTY_MODS_CTRL), (.option, GHOSTTY_MODS_ALT),
            (.command, GHOSTTY_MODS_SUPER), (.capsLock, GHOSTTY_MODS_CAPS),
        ] where flags.contains(flag) { bits |= bit.rawValue }
        return ghostty_input_mods_e(rawValue: bits)
    }

    private func translationEvent(_ event: NSEvent) -> NSEvent {
        guard let surface else { return event }
        let translated = ghostty_surface_key_translation_mods(surface, Self.modifiers(event.modifierFlags)).rawValue
        var flags = event.modifierFlags
        for (flag, bit) in [
            (NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT), (.control, GHOSTTY_MODS_CTRL),
            (.option, GHOSTTY_MODS_ALT), (.command, GHOSTTY_MODS_SUPER),
        ] {
            if translated & bit.rawValue == 0 { flags.remove(flag) } else { flags.insert(flag) }
        }
        guard flags != event.modifierFlags else { return event }
        return NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: flags, timestamp: event.timestamp,
            windowNumber: event.windowNumber, context: nil, characters: event.characters(byApplyingModifiers: flags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: event.isARepeat, keyCode: event.keyCode
        ) ?? event
    }
}

extension GhosttySurfaceView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        unmarkText()
        guard !text.isEmpty else { return }
        if interpretingKey {
            committedText.append(text)
        } else if let surface {
            text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        markedTextRange = text.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: text.utf16.count)
        selectedTextRange = selectedRange
        if let surface { text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.utf8.count)) } }
    }

    func unmarkText() {
        markedTextRange = NSRange(location: NSNotFound, length: 0)
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
    }

    func hasMarkedText() -> Bool { markedTextRange.location != NSNotFound }
    func markedRange() -> NSRange { markedTextRange }
    func selectedRange() -> NSRange { selectedTextRange }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        return window.convertToScreen(convert(NSRect(x: x, y: bounds.height - y - height, width: width, height: height), to: nil))
    }
}
