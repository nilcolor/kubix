import Foundation

public struct ShellPathResult: Sendable {
    public let path: String
    public let usedFallback: Bool
    public let diagnostic: String?

    public init(path: String, usedFallback: Bool = false, diagnostic: String? = nil) {
        self.path = path
        self.usedFallback = usedFallback
        self.diagnostic = diagnostic
    }
}

public protocol ShellPathProviding: Sendable {
    func baseline(environment: [String: String]) async -> ShellPathResult
}

/// Best effort only. The probe is an *interactive* login shell (`-ilc`) because that is where tool
/// managers actually put themselves: Homebrew, mise, asdf and rbenv are configured in `.zshrc`, which
/// a plain `-lc` login shell never reads — and a Finder-launched app inherits none of it, so without
/// this a GUI launch cannot see any of the user's tools. It still cannot recover setup that an rc file
/// guards behind a TTY check; the marker framing exists because an interactive rc file may print.
public struct ShellPath: ShellPathProviding {
    static let arguments = "-ilc"
    /// Measured, not chosen for symmetry with unrelated drain bounds: a real interactive shell loading
    /// version managers takes seconds, so a budget that only suited `-lc` would time out and silently
    /// fall back to a PATH without the user's tools. Bounded so a hung rc file cannot stall auth, and
    /// the result is cached per settings revision, so the cost is paid once.
    static let timeout: TimeInterval = 10
    private let runner: any ProcessRunning
    public init(runner: any ProcessRunning = ProcessRunner()) { self.runner = runner }

    public func baseline(environment: [String: String]) async -> ShellPathResult {
        let inherited = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        guard let shell = environment["SHELL"], shell.hasPrefix("/") else { return fallback(inherited) }
        do {
            let result = try await runner.run(ProcessRequest(
                executable: URL(fileURLWithPath: shell),
                arguments: [Self.arguments, "printf '\\036%s\\037' \"$PATH\""],
                environment: environment, timeout: Self.timeout
            ), progress: { _ in })
            guard result.exitCode == 0,
                  let text = String(data: result.stdout, encoding: .utf8),
                  let start = text.lastIndex(of: "\u{1e}"), let end = text[start...].firstIndex(of: "\u{1f}") else {
                return fallback(inherited)
            }
            let path = String(text[text.index(after: start)..<end])
            guard !path.isEmpty, !path.contains("\n"), !path.contains("\0") else { return fallback(inherited) }
            return ShellPathResult(path: path)
        } catch { return fallback(inherited) }
    }

    private func fallback(_ path: String) -> ShellPathResult {
        ShellPathResult(
            path: path, usedFallback: true,
            diagnostic: "Login-shell PATH discovery failed; using inherited PATH. Configure Plugin Path for interactive shims."
        )
    }
}
