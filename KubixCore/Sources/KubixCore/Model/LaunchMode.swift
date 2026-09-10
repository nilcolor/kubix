public enum LaunchMode: Equatable, Sendable {
    case app
    case ptyBridge

    public enum ArgumentError: Error, Equatable, Sendable {
        case unsupportedArguments
    }

    /// Arguments exclude argv[0]. The bridge takes no arguments; its configuration will use env vars.
    public init(arguments: [String]) throws {
        switch arguments {
        case []:
            self = .app
        case ["--pty-bridge"]:
            self = .ptyBridge
        default:
            throw ArgumentError.unsupportedArguments
        }
    }
}
