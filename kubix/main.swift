import Darwin
import Foundation
import KubixCore
import KubixRuntime

do {
    switch try LaunchMode(arguments: Array(CommandLine.arguments.dropFirst())) {
    case .app:
        KubixApp.main()
    case .ptyBridge:
        exit(PTYBridgeChild.main())
    }
} catch {
    FileHandle.standardError.write(Data("usage: kubix [--pty-bridge]\n".utf8))
    exit(EX_USAGE)
}
