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

/// Best effort only: -lc does NOT read zsh's .zshrc or recover interactive mise/asdf activation.
public struct ShellPath: ShellPathProviding {
    private let runner: any ProcessRunning
    public init(runner: any ProcessRunning = ProcessRunner()) { self.runner = runner }

    public func baseline(environment: [String: String]) async -> ShellPathResult {
        let inherited = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        guard let shell = environment["SHELL"], shell.hasPrefix("/") else { return fallback(inherited) }
        do {
            let result = try await runner.run(ProcessRequest(
                executable: URL(fileURLWithPath: shell),
                arguments: ["-lc", "printf '\\036%s\\037' \"$PATH\""], environment: environment, timeout: 2
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
