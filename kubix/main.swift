import Darwin
import Foundation
import KubixCore

do {
    switch try LaunchMode(arguments: Array(CommandLine.arguments.dropFirst())) {
    case .app:
        KubixApp.main()
    case .ptyBridge:
        FileHandle.standardError.write(Data("kubix: --pty-bridge is not implemented yet\n".utf8))
        exit(EX_UNAVAILABLE)
    }
} catch {
    FileHandle.standardError.write(Data("usage: kubix [--pty-bridge]\n".utf8))
    exit(EX_USAGE)
}
