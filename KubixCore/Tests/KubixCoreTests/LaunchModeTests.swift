import KubixCore
import Testing

@Test func noArgumentsSelectsApp() throws {
    #expect(try LaunchMode(arguments: []) == .app)
}

@Test func bridgeFlagSelectsBridge() throws {
    #expect(try LaunchMode(arguments: ["--pty-bridge"]) == .ptyBridge)
}

@Test(arguments: [
    ["--unknown"],
    ["--help"],
    ["pod"],
    [""],
    ["--pty-bridge=value"],
    ["--pty-bridge", "--unknown"],
    ["--unknown", "--pty-bridge"],
    ["--pty-bridge", "--pty-bridge"],
])
func unsupportedArgumentsAreRejected(arguments: [String]) {
    #expect(throws: LaunchMode.ArgumentError.unsupportedArguments) {
        try LaunchMode(arguments: arguments)
    }
}
