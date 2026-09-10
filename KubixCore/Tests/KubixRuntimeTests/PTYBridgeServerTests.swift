import Darwin
import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Suite struct PTYBridgeServerTests {
    @Test func stoppedListenerRejectsNewPeersEvenWhileADuplicateRemainsOpen() throws {
        let directory = try BridgeDirectoryCapture().create()
        defer { rmdir(directory) }
        let path = directory + "/session.sock"
        let listener = try OwnedBridgeListener(path: path)
        defer { listener.close() }
        let retained = dup(listener.descriptor)
        #expect(retained >= 0)
        defer { Darwin.close(retained) }
        let endpoint = try ExecBridgeEndpoint(socketPath: path, nonce: BridgeNonce(bytes: Data(repeating: 1, count: 32)))
        listener.stopAccepting()
        #expect(throws: BridgeIOError.self) { try BridgeServerClient(endpoint: endpoint) }
        #expect(fcntl(retained, F_GETFD) >= 0)
    }

    @Test func privateSocketAndDirectoryPermissionsRealIOAndFreshDirectoryAfterLastClose() async throws {
        let directories = BridgeDirectoryCapture()
        let server = PTYBridgeServer(makeDirectory: { try directories.create() })
        for _ in 0..<2 {
            try await withServerSession(server: server) { session, client in
                let endpoint = session.endpoint
                let directory = try #require(directories.created.last)
                #expect(try bridgeFileMode(directory) == 0o700)
                #expect(try bridgeFileMode(endpoint.socketPath) == 0o600)
                #expect(endpoint.socketPath.utf8.count + 1 <= 104)
                try await client.handshake(endpoint)
                #expect(try await session.initialSize() == BridgeSize(columns: 90, rows: 30))
                try await client.write(BridgeFrame.data(Data([3, 4, 0xff])).encoded() + BridgeFrame.closeInput.encoded())
                #expect(try await session.receive() == .data(Data([3, 4, 0xff])))
                #expect(try await session.receive() == .closeInput)
                try await session.send(.data(Data([0, 10, 255])))
                try await session.send(.exit(code: 37))
                #expect(try await client.frame() == .data(Data([0, 10, 255])))
                #expect(try await client.frame() == .exit(code: 37))
                await session.close()
                await session.close()
                #expect(!bridgeFileExists(endpoint.socketPath))
                #expect(!bridgeFileExists(directory))
            }
        }
        #expect(Set(directories.created).count == 2)
    }

    @Test func simultaneousSessionsShareDirectoryButOwnSeparateNoncesAndSockets() async throws {
        let directories = BridgeDirectoryCapture()
        let server = PTYBridgeServer(makeDirectory: { try directories.create() })
        let id = UUID()
        let first = try await server.prepare(sessionID: id)
        let second = try await server.prepare(sessionID: UUID())
        await #expect(throws: BridgeIOError.self) { try await server.prepare(sessionID: id) }
        #expect(first.endpoint.socketPath != second.endpoint.socketPath)
        #expect(first.endpoint.nonce != second.endpoint.nonce)
        #expect(directories.created.count == 1)
        await first.close()
        #expect(!bridgeFileExists(first.endpoint.socketPath))
        #expect(bridgeFileExists(second.endpoint.socketPath))
        #expect(bridgeFileExists(directories.created[0]))
        await second.close()
        #expect(!bridgeFileExists(directories.created[0]))
    }

    @Test(arguments: ["nonce", "data-first", "oversize", "missing-resize"])
    func malformedOrUnauthenticatedFirstAttemptFailsClosed(kind: String) async throws {
        let directories = BridgeDirectoryCapture()
        let server = PTYBridgeServer(makeDirectory: { try directories.create() })
        try await withServerSession(server: server) { session, client in
            let bytes: Data
            switch kind {
            case "nonce": bytes = try BridgeFrame.hello(BridgeNonce(bytes: Data(repeating: 0, count: 32))).encoded()
            case "data-first": bytes = try BridgeFrame.data(Data([65])).encoded()
            case "oversize": bytes = Data([1, 255, 255, 255, 255])
            default:
                bytes = try BridgeFrame.hello(session.endpoint.nonce).encoded() + BridgeFrame.data(Data([65])).encoded()
            }
            try await client.write(bytes)
            await #expect(throws: BridgeProtocolError.self) { try await session.initialSize() }
            #expect(!bridgeFileExists(session.endpoint.socketPath))
            await #expect(throws: BridgeProtocolError.self) { try await session.initialSize() }
            #expect(throws: BridgeIOError.self) { try BridgeServerClient(endpoint: session.endpoint) }
        }
        #expect(directories.created.allSatisfy { !bridgeFileExists($0) })
    }

    @Test func nonceCannotBeReusedOrSecondPeerAcceptedAfterSuccessfulHandshake() async throws {
        let directories = BridgeDirectoryCapture()
        let server = PTYBridgeServer(makeDirectory: { try directories.create() })
        try await withServerSession(server: server) { session, client in
            try await client.handshake(session.endpoint)
            _ = try await session.initialSize()
            #expect(throws: BridgeIOError.self) { try BridgeServerClient(endpoint: session.endpoint) }
            try await client.write(BridgeFrame.hello(session.endpoint.nonce).encoded())
            await #expect(throws: BridgeProtocolError.unexpectedFrame) { try await session.receive() }
        }
        #expect(directories.created.allSatisfy { !bridgeFileExists($0) })
    }

    @Test(arguments: ["no-peer", "silent-peer", "hello-only"])
    func boundedHandshakeTimeoutClosesListenerAndRemovesOwnedPaths(stage: String) async throws {
        let directories = BridgeDirectoryCapture()
        let clock = ManualTransportClock()
        let server = PTYBridgeServer(makeDirectory: { try directories.create() }, clock: clock, handshakeTimeout: 3)
        let session = try await server.prepare(sessionID: UUID())
        let client = stage == "no-peer" ? nil : try BridgeServerClient(endpoint: session.endpoint)
        if stage == "hello-only" { try await client?.write(BridgeFrame.hello(session.endpoint.nonce).encoded()) }
        clock.advance(to: 3)
        await #expect(throws: BridgeIOError.self) { try await session.initialSize() }
        await client?.close()
        await session.close()
        #expect(directories.created.allSatisfy { !bridgeFileExists($0) })
    }

    @Test func actualSilentPeerTimesOutWithContinuousClock() async throws {
        let directories = BridgeDirectoryCapture()
        let server = PTYBridgeServer(makeDirectory: { try directories.create() }, handshakeTimeout: 0.05)
        try await withServerSession(server: server) { session, _ in
            await #expect(throws: BridgeIOError.self) { try await session.initialSize() }
        }
        #expect(directories.created.allSatisfy { !bridgeFileExists($0) })
    }

    @Test func longInjectedPathIsRejectedBeforeBindingAndOwnedDirectoryIsRemoved() async throws {
        let directories = BridgeDirectoryCapture()
        let server = PTYBridgeServer(makeDirectory: { try directories.create(suffix: String(repeating: "x", count: 48) + "-XXXXXX") })
        await #expect(throws: BridgeProtocolError.socketPathTooLong) { try await server.prepare(sessionID: UUID()) }
        #expect(directories.created.count == 1)
        #expect(!bridgeFileExists(directories.created[0]))
    }

    @Test func cleanupNeverRecursesOrDeletesAnUnownedEntry() async throws {
        let directories = BridgeDirectoryCapture()
        let server = PTYBridgeServer(makeDirectory: { try directories.create() })
        let session = try await server.prepare(sessionID: UUID())
        let directory = try #require(directories.created.first)
        let other = directory + "/unowned"
        let fd = open(other, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        #expect(fd >= 0)
        Darwin.close(fd)
        await session.close()
        #expect(!bridgeFileExists(session.endpoint.socketPath))
        #expect(bridgeFileExists(other))
        #expect(bridgeFileExists(directory))
        #expect(unlink(other) == 0)
        #expect(rmdir(directory) == 0)
    }

    @Test func cleanupDoesNotUnlinkAReplacementAtItsFormerSocketPath() async throws {
        let directories = BridgeDirectoryCapture()
        let server = PTYBridgeServer(makeDirectory: { try directories.create() })
        let session = try await server.prepare(sessionID: UUID())
        let path = session.endpoint.socketPath
        let moved = path + ".old"
        #expect(rename(path, moved) == 0)
        let replacement = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        #expect(replacement >= 0)
        Darwin.close(replacement)
        await session.close()
        #expect(bridgeFileExists(path))
        #expect(bridgeFileExists(moved))
        #expect(unlink(path) == 0)
        #expect(unlink(moved) == 0)
        #expect(rmdir(directories.created[0]) == 0)
    }
}

@Suite struct PTYBridgeServerCancellationTests {
    @Test(arguments: [Data([1, 0]), Data([1, 0, 0, 0, 32, 7, 7])])
    func truncatedHandshakeIsRejectedAndDoesNotLeakListener(bytes: Data) async throws {
        let directories = BridgeDirectoryCapture()
        let server = PTYBridgeServer(makeDirectory: { try directories.create() })
        try await withServerSession(server: server) { session, client in
            try await client.write(bytes)
            await client.closeInput()
            await #expect(throws: BridgeProtocolError.truncatedFrame) { try await session.initialSize() }
        }
        #expect(directories.created.allSatisfy { !bridgeFileExists($0) })
    }

    @Test func failedBindNeverUnlinksAnExistingFile() async throws {
        let directories = BridgeDirectoryCapture()
        let directory = try directories.create()
        let id = UUID()
        let path = try BridgeSocketPath(runtimeDirectory: directory, sessionID: id).value
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        #expect(fd >= 0)
        Darwin.close(fd)
        let server = PTYBridgeServer(makeDirectory: { directory })
        await #expect(throws: BridgeIOError.self) { try await server.prepare(sessionID: id) }
        #expect(bridgeFileExists(path))
        #expect(unlink(path) == 0)
        #expect(rmdir(directory) == 0)
    }

    @Test func cancelAcceptReadAndBlockedWriteUnblocksWithoutDescriptorReuse() async throws {
        let directories = BridgeDirectoryCapture()
        let server = PTYBridgeServer(makeDirectory: { try directories.create() })
        let waiting = try await server.prepare(sessionID: UUID())
        let accept = Task { try await waiting.initialSize() }
        accept.cancel()
        await #expect(throws: CancellationError.self) { try await accept.value }
        await waiting.close()
        #expect(!bridgeFileExists(waiting.endpoint.socketPath))

        try await withServerSession(server: server) { session, client in
            try await client.handshake(session.endpoint)
            _ = try await session.initialSize()
            let read = Task { try await session.receive() }
            read.cancel()
            await #expect(throws: CancellationError.self) { try await read.value }
            let write = Task {
                while true { try await session.send(.data(Data(repeating: 65, count: 65_536))) }
            }
            try await Task.sleep(for: .milliseconds(40))
            write.cancel()
            await #expect(throws: CancellationError.self) { try await write.value }
            // An interrupted partial frame poisons the writer rather than interleaving a failure.
            await #expect(throws: BridgeIOError.self) { try await session.send(.failure(.cancelled)) }
            await session.close()
        }
        #expect(directories.created.allSatisfy { !bridgeFileExists($0) })
    }

    @Test func realPeerEOFAndInvalidPostHalfCloseInputAreVisible() async throws {
        let directories = BridgeDirectoryCapture()
        let server = PTYBridgeServer(makeDirectory: { try directories.create() })
        try await withServerSession(server: server) { session, client in
            try await client.handshake(session.endpoint)
            _ = try await session.initialSize()
            await client.close()
            await #expect(throws: ExecFailure.childTerminated) { try await session.receive() }
        }
        try await withServerSession(server: server) { session, client in
            try await client.handshake(session.endpoint)
            _ = try await session.initialSize()
            try await client.write(BridgeFrame.closeInput.encoded() + BridgeFrame.data(Data([4])).encoded())
            #expect(try await session.receive() == .closeInput)
            await #expect(throws: BridgeProtocolError.unexpectedFrame) { try await session.receive() }
        }
        #expect(directories.created.allSatisfy { !bridgeFileExists($0) })
    }
}
