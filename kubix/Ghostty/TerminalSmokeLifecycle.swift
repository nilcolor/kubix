#if DEBUG
import AppKit
import GhosttyKit
import KubixCore

@MainActor
enum TerminalSmokeLifecycle {
    private enum CheckError: Error { case failed }

    static func check(configuration: TerminalConfiguration) async throws {
        let environment = Dictionary(uniqueKeysWithValues: configuration.environment.map { ($0.key, $0.value) })
        for wait in [false, true] {
            let config = try TerminalConfiguration(
                command: "/bin/zsh -f -c 'printf \"KUBIX_COMMAND\\n\"; exit 7'",
                environment: environment, workingDirectory: configuration.workingDirectory, waitAfterCommand: wait
            )
            try await checkCommand(config)
        }
        let initial = try TerminalConfiguration(
            environment: environment, workingDirectory: configuration.workingDirectory,
            initialInput: "printf 'KUBIX_%s\\n' INITIAL\n"
        )
        try await checkWindowClose(initial)
        let unmounted = LocalTerminalSession(configuration: configuration)
        guard let view = unmounted.view, view.surface == nil else { throw CheckError.failed }
        unmounted.close()
        view.setFrameSize(NSSize(width: 400, height: 300))
        guard view.isDestroyed, view.surface == nil, view.freeCount == 0 else { throw CheckError.failed }
    }

    private static func checkCommand(_ configuration: TerminalConfiguration) async throws {
        let session = LocalTerminalSession(configuration: configuration)
        guard let view = session.view else { throw CheckError.failed }
        let window = host(view)
        defer { session.close(); window.close() }
        if configuration.waitAfterCommand {
            try await TerminalSmokeTest.until {
                guard let surface = view.surface else { return false }
                return ghostty_surface_process_exited(surface)
            }
            guard !session.isClosed, view.freeCount == 0,
                  TerminalSmokeTest.viewport(view).contains("KUBIX_COMMAND") else { throw CheckError.failed }
            try TerminalSmokeTest.type("\n", in: window)
        }
        try await TerminalSmokeTest.until { session.isClosed }
        guard view.isDestroyed, view.surface == nil, view.freeCount == 1 else { throw CheckError.failed }
    }

    private static func checkWindowClose(_ configuration: TerminalConfiguration) async throws {
        let session = LocalTerminalSession(configuration: configuration)
        guard let view = session.view else { throw CheckError.failed }
        let window = host(view)
        defer { session.close(); window.close() }
        try await TerminalSmokeTest.until { TerminalSmokeTest.viewport(view).contains("KUBIX_INITIAL") }
        let pid = ghostty_surface_foreground_pid(view.surface)
        guard pid > 0 else { throw CheckError.failed }
        window.close()
        try await TerminalSmokeTest.until { kill(pid_t(pid), 0) == -1 && errno == ESRCH }
        guard session.isClosed, view.isDestroyed, view.freeCount == 1 else { throw CheckError.failed }
    }

    private static func host(_ view: GhosttySurfaceView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 180, y: 180, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        return window
    }
}
#endif
