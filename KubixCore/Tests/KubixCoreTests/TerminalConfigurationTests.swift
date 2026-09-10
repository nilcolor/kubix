import Foundation
import KubixCore
import Testing

@Test(arguments: [
    "/Applications/Kubix.app/Contents/MacOS/kubix",
    "/Applications/Kubix development.app/Contents/MacOS/kubix",
    "/Applications/owner's \"Kubix\" $HOME `echo bad`.app/kubix",
])
func bridgeSurfaceQuotesExecutableAndKeepsNonceOutOfArguments(path: String) throws {
    let endpoint = try ExecBridgeEndpoint(
        socketPath: "/synthetic/terminal.sock", nonce: BridgeNonce(bytes: Data(repeating: 17, count: 32))
    )
    let configuration = try TerminalConfiguration.bridge(executablePath: path, endpoint: endpoint)
    #expect(configuration.command == "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' --pty-bridge")
    #expect(configuration.environment.map(\.key) == ["KUBIX_BRIDGE_NONCE", "KUBIX_BRIDGE_SOCK"])
    #expect(Dictionary(uniqueKeysWithValues: configuration.environment.map { ($0.key, $0.value) }) == endpoint.environment)
    #expect(configuration.command?.contains(endpoint.nonce.environmentValue) == false)
    #expect(configuration.command?.contains(endpoint.socketPath) == false)
    #expect(configuration.initialInput == nil)
    #expect(configuration.workingDirectory == "/")
    #expect(!configuration.waitAfterCommand)
}

@Test func bridgeSurfaceRejectsRelativeAndNullExecutablePaths() throws {
    let endpoint = try ExecBridgeEndpoint(
        socketPath: "/synthetic/terminal.sock", nonce: BridgeNonce(bytes: Data(repeating: 17, count: 32))
    )
    #expect(throws: TerminalConfiguration.ConfigurationError.relativeExecutable) {
        try TerminalConfiguration.bridge(executablePath: "kubix", endpoint: endpoint)
    }
    #expect(throws: TerminalConfiguration.ConfigurationError.invalidCString) {
        try TerminalConfiguration.bridge(executablePath: "/app\0/injected", endpoint: endpoint)
    }
}
