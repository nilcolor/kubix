import Foundation
import KubixCore
import Testing

@Test @MainActor func surfaceLifetimeClosesExactlyOnceAndReleasesOwnershipBeforeCallingAdapter() {
    let surface = CountingTerminalSurface()
    let owner = TerminalSurfaceLifetime(surface: surface)
    surface.onTeardown = {
        #expect(owner.surface == nil)
        owner.close()
    }
    #expect(owner.surface === surface)
    owner.close()
    owner.close()
    #expect(surface.teardownCount == 1)
    #expect(owner.surface == nil)
}

@Test @MainActor func surfaceIsRetainedUntilSessionCloses() {
    var adapter: CountingTerminalSurface? = CountingTerminalSurface()
    weak var weakAdapter = adapter
    let owner = TerminalSurfaceLifetime(surface: adapter!)
    adapter = nil
    #expect(weakAdapter != nil)
    owner.close()
    #expect(weakAdapter == nil)
}

@Test func terminalConfigurationDefaultsToLoginShell() {
    let config = TerminalConfiguration.loginShell
    #expect(config.command == nil)
    #expect(config.initialInput == nil)
    #expect(config.workingDirectory == nil)
    #expect(config.environment.isEmpty)
    #expect(!config.waitAfterCommand)
}

@Test func terminalConfigurationPreservesMarshalingInputsAndSortsEnvironment() throws {
    let config = try TerminalConfiguration(
        command: "/path with spaces/kubix --pty-bridge", environment: ["Z": "", "A": "値=a\nb"],
        workingDirectory: "/a path/é", waitAfterCommand: true
    )
    #expect(config.command == "/path with spaces/kubix --pty-bridge")
    #expect(config.workingDirectory == "/a path/é")
    #expect(config.waitAfterCommand)
    #expect(config.environment.map(\.key) == ["A", "Z"])
    #expect(config.environment.map(\.value) == ["値=a\nb", ""])
    #expect(try TerminalConfiguration(initialInput: "printf 'hello'\n").initialInput == "printf 'hello'\n")
}

@Test func terminalConfigurationRejectsTruncationAndInvalidInputs() {
    #expect(throws: TerminalConfiguration.ConfigurationError.invalidCString) { try TerminalConfiguration(command: "echo\0hidden") }
    #expect(throws: TerminalConfiguration.ConfigurationError.invalidCString) { try TerminalConfiguration(environment: ["A": "\0"]) }
    #expect(throws: TerminalConfiguration.ConfigurationError.invalidCString) { try TerminalConfiguration(environment: ["A\0B": "x"]) }
    #expect(throws: TerminalConfiguration.ConfigurationError.invalidCString) { try TerminalConfiguration(workingDirectory: "/a\0b") }
    #expect(throws: TerminalConfiguration.ConfigurationError.invalidCString) { try TerminalConfiguration(initialInput: "a\0b") }
    #expect(throws: TerminalConfiguration.ConfigurationError.invalidEnvironmentKey) { try TerminalConfiguration(environment: ["": "x"]) }
    #expect(throws: TerminalConfiguration.ConfigurationError.invalidEnvironmentKey) { try TerminalConfiguration(environment: ["A=B": "x"]) }
    #expect(throws: TerminalConfiguration.ConfigurationError.emptyCommand) { try TerminalConfiguration(command: "") }
    #expect(throws: TerminalConfiguration.ConfigurationError.relativeWorkingDirectory) { try TerminalConfiguration(workingDirectory: "~") }
    #expect(throws: TerminalConfiguration.ConfigurationError.conflictingInitialInput) {
        try TerminalConfiguration(command: "echo hello", initialInput: "ignored")
    }
}

@Test(arguments: ["78", "x"]) func resourcePathsRequireSiblingTerminfo(prefix: String) throws {
    let base = URL(fileURLWithPath: "/My Apps/Kubix.app/Contents/Resources", isDirectory: true)
    let markers = Set([base.path + "/ghostty/shell-integration", base.path + "/terminfo/\(prefix)/xterm-ghostty"])
    let paths = try TerminalResourcePaths(bundleResources: base) { markers.contains($0.path) }
    #expect(paths.ghostty.path == base.path + "/ghostty")
    #expect(paths.terminfo.path == base.path + "/terminfo")
}

@Test func resourcePathsFailClosedWhenIncompleteOrIncorrectlyNested() {
    let base = URL(fileURLWithPath: "/Resources", isDirectory: true)
    for markers in [Set<String>(), ["/Resources/ghostty/shell-integration"],
                    ["/Resources/terminfo/78/xterm-ghostty"],
                    ["/Resources/ghostty/shell-integration", "/Resources/ghostty/terminfo/78/xterm-ghostty"]] {
        #expect(throws: TerminalResourcePaths.ResourceError.missingResources) {
            try TerminalResourcePaths(bundleResources: base) { markers.contains($0.path) }
        }
    }
    #expect(throws: TerminalResourcePaths.ResourceError.missingResources) {
        try TerminalResourcePaths(bundleResources: URL(string: "https://example.invalid")!) { _ in true }
    }
}

@MainActor private final class CountingTerminalSurface: TerminalSurface {
    var teardownCount = 0
    var onTeardown: (() -> Void)?
    func teardown() {
        teardownCount += 1
        let callback = onTeardown
        onTeardown = nil
        callback?()
    }
}
