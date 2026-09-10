// Bridge architecture adapted from thdxg/macterm (MIT), via agterm.
// Copyright (c) 2026 Macterm. See Resources/ThirdPartyNotices.txt.

import AppKit
import GhosttyKit
import KubixCore
import QuartzCore

final class GhosttySurfaceView: NSView, TerminalSurface {
    nonisolated let configuration: TerminalConfiguration
    private(set) var surface: ghostty_surface_t?
    private(set) var isDestroyed = false
    private(set) var freeCount = 0
    private var strings: [UnsafeMutablePointer<CChar>] = []
    private var environment: [ghostty_env_var_s] = []
    private var mouseTracking: NSTrackingArea?
    var onClose: (() -> Void)?
    var onFailure: (() -> Void)?

    var interpretingKey = false
    var committedText: [String] = []
    var markedTextRange = NSRange(location: NSNotFound, length: 0)
    var selectedTextRange = NSRange(location: 0, length: 0)

    init(configuration: TerminalConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        wantsLayer = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowClosing(_:)), name: NSWindow.willCloseNotification, object: nil)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(self, selector: #selector(focusChanged), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func cString(_ string: String?) throws -> UnsafePointer<CChar>? {
        guard let string else { return nil }
        guard let pointer = strdup(string) else { throw SurfaceError.allocationFailed }
        strings.append(pointer)
        return UnsafePointer(pointer)
    }

    private enum SurfaceError: Error { case allocationFailed }

    private func createSurfaceIfReady() {
        guard !isDestroyed, surface == nil, let window, let app = GhosttyApp.shared.app else { return }
        let size = convertToBacking(bounds).size
        guard size.width > 0, size.height > 0 else { return }
        do {
            var config = ghostty_surface_config_new()
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
            config.userdata = Unmanaged.passUnretained(self).toOpaque()
            config.scale_factor = Double(window.backingScaleFactor)
            config.command = try cString(configuration.command)
            config.working_directory = try cString(configuration.workingDirectory)
            config.initial_input = try cString(configuration.initialInput)
            config.wait_after_command = configuration.waitAfterCommand
            for entry in configuration.environment {
                let key = try cString(entry.key)
                let value = try cString(entry.value)
                environment.append(ghostty_env_var_s(key: key, value: value))
            }
            // The array pointer cannot escape this closure; Ghostty copies its entries during new().
            // All pointed-to strings, including asynchronously consumed initial_input, live until free().
            surface = environment.withUnsafeMutableBufferPointer { buffer in
                config.env_vars = buffer.baseAddress
                config.env_var_count = buffer.count
                return ghostty_surface_new(app, &config)
            }
            guard surface != nil else { throw SurfaceError.allocationFailed }
            updateGeometry()
            updateColorScheme()
            window.makeFirstResponder(self)
            focusChanged()
        } catch {
            let report = onFailure
            destroySurface()
            report?()
        }
    }

    func teardown() { destroySurface() }

    /// The only surface-free path. The owning session retains self through this entire call.
    private func destroySurface() {
        guard !isDestroyed else { return }
        isDestroyed = true
        if let surface {
            self.surface = nil
            ghostty_surface_free(surface)
            freeCount += 1
        }
        strings.forEach { free($0) }
        strings.removeAll()
        environment.removeAll()
        onClose = nil
        onFailure = nil
    }

    func requestClose() {
        guard !isDestroyed else { return }
        onClose?()
    }

    func applyTitle(_ title: String) {
        guard !isDestroyed else { return }
        window?.title = title.isEmpty ? "Kubix" : title
    }

    func render() {
        if let surface { ghostty_surface_draw(surface) }
    }

    @objc private func windowClosing(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        requestClose()
    }

    @objc private func focusChanged() {
        if let surface { ghostty_surface_set_focus(surface, window?.isKeyWindow == true && window?.firstResponder === self) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        createSurfaceIfReady()
        updateGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        createSurfaceIfReady()
        updateGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGeometry()
    }

    private func updateGeometry() {
        guard let surface, let window else { return }
        let size = convertToBacking(bounds).size
        guard size.width > 0, size.height > 0 else { return }
        let scale = window.backingScaleFactor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        CATransaction.commit()
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(clamping: Int(size.width)), UInt32(clamping: Int(size.height)))
        if let display = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            ghostty_surface_set_display_id(surface, display)
        }
        ghostty_surface_refresh(surface)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColorScheme()
    }

    private func updateColorScheme() {
        guard let surface else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_surface_set_color_scheme(surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, window?.isKeyWindow == true) }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        mouseTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, Self.modifiers(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) { mouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT) }
    override func rightMouseDown(with event: NSEvent) { mouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT) }
    override func rightMouseUp(with event: NSEvent) { mouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT) }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    private func mouseButton(_ event: NSEvent, state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e) {
        guard let surface else { return }
        mouseMoved(with: event)
        _ = ghostty_surface_mouse_button(surface, state, button, Self.modifiers(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        if let surface {
            ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas ? 1 : 0)
        }
    }

    @objc func copy(_ sender: Any?) {
        guard let surface else { return }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return }
        let copied = String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copied, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let surface, let text = NSPasteboard.general.string(forType: .string) else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "c": copy(nil)
        case "v": paste(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
