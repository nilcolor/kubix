import Darwin
import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Suite struct PTYTerminalTests {
    @Test func rawModeDisablesEveryLocalDisciplineAndRestoresSavedAttributes() throws {
        let pty = try TestPTY()
        let terminal = try PTYTerminal(descriptor: pty.terminal)
        try terminal.makeRaw()
        let raw = try PTYSnapshot(pty.terminal)
        #expect(raw.flags[0] & tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON) == 0)
        #expect(raw.flags[1] & tcflag_t(OPOST) == 0)
        #expect(raw.flags[3] & tcflag_t(ECHO | ICANON | ISIG | IEXTEN) == 0)
        #expect(try terminal.size() == BridgeSize(columns: 80, rows: 24))
        try terminal.restore()
        try terminal.restore()
        let restored = try PTYSnapshot(pty.terminal)
        #expect(restored.flags == pty.original.flags)
        #expect(restored.controls == pty.original.controls)
        #expect(restored.speeds == pty.original.speeds)
        #expect(fcntl(pty.terminal, F_GETFD) >= 0)
    }

    @Test func fallbackRestorationRunsWhenOwnerLeavesScope() throws {
        let pty = try TestPTY()
        do {
            let terminal = try PTYTerminal(descriptor: pty.terminal)
            try terminal.makeRaw()
            #expect(try PTYSnapshot(pty.terminal) != pty.original)
        }
        #expect(try PTYSnapshot(pty.terminal) == pty.original)
    }

    @Test func pipeIsNotATerminalAndCallerDescriptorIsNotClosed() throws {
        let pipe = try TestBridgePipe()
        #expect(throws: BridgeIOError.self) { try PTYTerminal(descriptor: pipe.reader) }
        #expect(fcntl(pipe.reader, F_GETFD) >= 0)
    }

    @Test func sharedOpenFileFlagsAndNoSigpipeAreRestored() throws {
        let pty = try TestPTY()
        let flags = fcntl(pty.terminal, F_GETFL)
        let signal = fcntl(pty.terminal, F_GETNOSIGPIPE)
        do {
            let descriptors = try PTYBridgeDescriptors(input: pty.terminal, output: pty.terminal)
            try descriptors.prepare()
            #expect(fcntl(pty.terminal, F_GETFL) & O_NONBLOCK != 0)
            #expect(fcntl(pty.terminal, F_GETNOSIGPIPE) == 1)
        }
        #expect(fcntl(pty.terminal, F_GETFL) == flags)
        #expect(fcntl(pty.terminal, F_GETNOSIGPIPE) == signal)
    }

    @Test func brokenDiagnosticPipeDoesNotSignalOrHang() throws {
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        Darwin.close(fds[0])
        defer { Darwin.close(fds[1]) }
        let flags = fcntl(fds[1], F_GETFL)
        PTYBridgeDiagnostic.write("kubix: The terminal connection failed.\n", descriptor: fds[1])
        #expect(fcntl(fds[1], F_GETFL) == flags)
    }
}
