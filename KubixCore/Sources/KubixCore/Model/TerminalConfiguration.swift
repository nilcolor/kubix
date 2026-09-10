import Foundation

public struct TerminalConfiguration: Sendable, Equatable {
    public struct EnvironmentVariable: Sendable, Equatable {
        public let key: String
        public let value: String
    }

    public enum ConfigurationError: Error, Equatable {
        case invalidCString
        case invalidEnvironmentKey
        case emptyCommand
        case relativeWorkingDirectory
        case conflictingInitialInput
    }

    public let command: String?
    public let workingDirectory: String?
    public let initialInput: String?
    public let waitAfterCommand: Bool
    public let environment: [EnvironmentVariable]

    public static let loginShell = try! TerminalConfiguration()

    public init(
        command: String? = nil,
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        initialInput: String? = nil,
        waitAfterCommand: Bool = false
    ) throws {
        let strings = [command, workingDirectory, initialInput].compactMap { $0 }
            + Array(environment.keys) + Array(environment.values)
        guard !strings.contains(where: { $0.utf8.contains(0) }) else { throw ConfigurationError.invalidCString }
        guard environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") }) else {
            throw ConfigurationError.invalidEnvironmentKey
        }
        guard command != "" else { throw ConfigurationError.emptyCommand }
        if let workingDirectory, !workingDirectory.hasPrefix("/") { throw ConfigurationError.relativeWorkingDirectory }
        guard command == nil || initialInput == nil else { throw ConfigurationError.conflictingInitialInput }
        self.command = command
        self.workingDirectory = workingDirectory
        self.initialInput = initialInput
        self.waitAfterCommand = waitAfterCommand
        self.environment = environment.sorted { $0.key < $1.key }.map { EnvironmentVariable(key: $0.key, value: $0.value) }
    }
}

/// Pure derivation and injected existence checks; no Bundle, environment mutation, or filesystem IO.
public struct TerminalResourcePaths: Sendable, Equatable {
    public enum ResourceError: Error, Equatable { case missingResources }

    public let ghostty: URL
    public let terminfo: URL

    public init(bundleResources: URL, exists: (URL) -> Bool) throws {
        guard bundleResources.isFileURL else { throw ResourceError.missingResources }
        ghostty = bundleResources.appendingPathComponent("ghostty", isDirectory: true)
        terminfo = bundleResources.appendingPathComponent("terminfo", isDirectory: true)
        guard exists(ghostty.appendingPathComponent("shell-integration", isDirectory: true)),
              ["78", "x"].contains(where: { exists(terminfo.appendingPathComponent("\($0)/xterm-ghostty")) })
        else { throw ResourceError.missingResources }
    }
}
