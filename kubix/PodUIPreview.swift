#if DEBUG
import AppKit
import KubixCore

/// Puts the synthetic fixture's pods page on screen and leaves it there, so a layout change can be
/// looked at without a live cluster. Opt-in, and it drives nothing beyond Connect and a selection —
/// the smoke that follows the same fixture is where behaviour is asserted.
@MainActor enum PodUIPreview {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["KUBIX_POD_UI_PREVIEW"] == "1" }

    static func run(_ fixture: PodBrowsingFixture) async {
        let store = fixture.store
        fixture.actions.connect(contextNamed: "synthetic-first")
        try? await PodBrowsingValidation.until { store.clusters.first?.state == .connected }
        fixture.actions.selectSidebar(.list("synthetic-first", .pods))
        try? await PodBrowsingValidation.until { store.connection == .live }
        // One session of each kind, on different pods, so the deck's strip is worth looking at.
        fixture.actions.openPodShell(uid: "uid-a")
        try? await PodBrowsingValidation.until { store.execSessions.first?.state == .running }
        fixture.actions.openPodLogs(uid: "uid-z", container: "web")
        try? await PodBrowsingValidation.until { !store.logSessions.isEmpty }
        guard let window = NSApp.windows.first(where: \.isVisible),
              let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else { return }
        window.setContentSize(NSSize(width: 1180, height: 720))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Reported flipped against the zero-origin screen, which is the space a screen capture's
        // rectangle is in, so capturing just this window needs no guess at where it landed.
        let frame = window.frame
        let top = primary.frame.maxY - frame.maxY
        FileHandle.standardError.write(Data(
            "PREVIEW window rect \(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))\n".utf8
        ))
    }
}
#endif
