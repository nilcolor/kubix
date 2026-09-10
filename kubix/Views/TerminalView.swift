import KubixCore
import SwiftUI

/// Task 7's local session only: no Kubernetes client, credentials, or bridge child.
@MainActor @Observable
final class LocalTerminalSession {
    let id = UUID()
    private(set) var isClosed = false
    private(set) var failure: String?
    @ObservationIgnored private var lifetime: TerminalSurfaceLifetime?

    var view: GhosttySurfaceView? { lifetime?.surface as? GhosttySurfaceView }

    init(configuration: TerminalConfiguration = .loginShell) {
        let engine = GhosttyApp.shared
        guard engine.app != nil else {
            failure = engine.failure
            return
        }
        let view = GhosttySurfaceView(configuration: configuration)
        lifetime = TerminalSurfaceLifetime(surface: view)
        view.onClose = { [weak self] in self?.close() }
        view.onFailure = { [weak self] in
            self?.failure = "Unable to create the terminal surface."
            self?.close()
        }
        // The engine retains the session until explicit close, including while SwiftUI rehosts its view.
        engine.register(self)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        lifetime?.close()
        GhosttyApp.shared.unregister(id)
    }
}

struct TerminalView: NSViewRepresentable {
    let surface: GhosttySurfaceView
    var isSelected = true

    func makeNSView(context: Context) -> GhosttySurfaceView {
        surface.isHidden = !isSelected
        return surface
    }
    func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
        let wasHidden = nsView.isHidden
        nsView.isHidden = !isSelected
        if wasHidden && isSelected { nsView.window?.makeFirstResponder(nsView) }
    }

    static func dismantleNSView(_ nsView: GhosttySurfaceView, coordinator: ()) {
        // The session alone owns teardown. Dismantling/rehosting must not free a live PTY.
    }
}

#if DEBUG
struct TerminalSmokeView: View {
    @State private var session: LocalTerminalSession?

    var body: some View {
        Group {
            if let failure = session?.failure {
                ContentUnavailableView("Terminal unavailable", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else if session?.isClosed == true {
                ContentUnavailableView("Shell exited", systemImage: "terminal")
            } else if let surface = session?.view {
                TerminalView(surface: surface)
            } else {
                ProgressView("Starting terminal")
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .task {
            if session == nil { session = LocalTerminalSession(configuration: TerminalSmokeTest.configuration) }
            if let session { await TerminalSmokeTest.run(session) }
        }
    }
}
#endif
