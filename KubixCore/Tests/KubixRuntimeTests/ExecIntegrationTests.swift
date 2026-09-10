import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Suite @MainActor struct ExecIntegrationTests {
    @Test func expiredCredentialRefreshAndMissedPongNeverReplayRunningShell() async throws {
        let wall = RuntimeClock()
        let clock = ManualTransportClock()
        let process = FakeProcess { _, _ in
            let expiration = wall.now().addingTimeInterval(200).ISO8601Format()
            return ProcessResult(stdout: Data("""
            {"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential",
             "status":{"token":"synthetic-token","expirationTimestamp":"\(expiration)"}}
            """.utf8), exitCode: 0)
        }
        let fixture = try ExecIntegrationFixture(process: process, clock: clock, now: wall.now, pingGate: TestGate())
        defer { fixture.actions.shutdown() }
        let id = fixture.actions.openShell(target: fixture.target)
        try await sessionEventually { fixture.store.execSessions.first?.state == .running && clock.deadlines == [15] }
        let surface = try #require(fixture.surfaces.created[id])
        wall.set(1300)
        _ = try await fixture.auth.acquire(for: fixture.target.context)
        #expect(await process.requests().count == 2)
        #expect(await fixture.session.socketRequests.count == 1)
        #expect(fixture.store.execSessions.first?.state == .running && fixture.actions.surface(for: id) === surface)
        try bridgeWrite(surface.tty.controller, bytes: Data([120]))
        try await transportEventually { fixture.socket.sent.contains { $0 == Data([0, 120]) } }
        clock.advance(to: 15)
        try await transportEventually { clock.deadlines == [30] }
        clock.advance(to: 29)
        #expect(fixture.store.execSessions.first?.state == .running)
        clock.advance(to: 30)
        try await sessionEventually { fixture.store.execSessions.first?.state.isTerminal == true && surface.run.finished }
        #expect(fixture.store.execSessions.first?.state == .finished(.failed(.api(.transport(.pongTimedOut)))))
        #expect(try surface.run.wait() == .localFailure(.connection))
        #expect(fixture.socket.isCancelled)
        #expect(await fixture.session.socketRequests.count == 1)
        #expect(await process.requests().count == 2)
        await fixture.actions.shutdownAndWait()
        #expect(surface.closes == 1)
        try await transportEventually { clock.deadlines.isEmpty && fixture.directories.created.allSatisfy { !bridgeFileExists($0) } }
    }

    @Test(arguments: [false, true])
    func realAuthTransportServerAndRelayShareLoginAndKeepRemoteOutcomeAuthoritative(serverFailure: Bool) async throws {
        let loginGate = TestGate()
        let process = FakeProcess { request, progress in
            if request.arguments == ["--version"] { return ProcessResult(stdout: Data("aws-cli/2.99".utf8), exitCode: 0) }
            if request.arguments.first == "sso" {
                progress("https://synthetic.invalid/authorize SYNTHETIC-CODE")
                try await loginGate.wait()
                return ProcessResult(stdout: Data(), exitCode: 0)
            }
            return ProcessResult(stdout: syntheticCredential, exitCode: 0)
        }
        let fixture = try ExecIntegrationFixture(process: process)
        defer { fixture.actions.shutdown() }
        let context = fixture.target.context
        let login = Task { try await fixture.actions.signIn(context: context) }
        defer { login.cancel() }
        try await sessionEventually { fixture.store.authenticationSessions.values.contains { !$0.instructions.isEmpty } }
        let authID = try #require(fixture.store.authenticationSessions.values.first { !$0.instructions.isEmpty }?.id)
        let closed = fixture.actions.openShell(target: fixture.target)
        let active = fixture.actions.openShell(target: fixture.target)
        try await transportEventually { await fixture.auth.waiterCount(operationID: authID) == 3 }
        fixture.actions.closeShell(closed)
        try await transportEventually { await fixture.auth.waiterCount(operationID: authID) == 2 }
        #expect(fixture.directories.created.isEmpty)
        #expect(fixture.surfaces.created.isEmpty)
        #expect(await process.requests().count == 2)
        try fixture.actions.selectContext(named: "other")
        try fixture.actions.selectNamespace("other-namespace")
        await loginGate.open()
        try await login.value
        try await sessionEventually { fixture.surfaces.created[active] != nil && !fixture.socket.sent.isEmpty }
        let surface = try #require(fixture.surfaces.created[active])
        #expect(fixture.surfaces.created[closed] == nil)
        #expect(fixture.store.execSessions[1].target == fixture.target)
        #expect(await process.requests().count == 3)
        #expect(fixture.store.authenticationSessions.values.allSatisfy { $0.instructions.isEmpty })
        try await fixture.checkAuthenticatedInputAndResize(surface)
        try await checkOutcome(fixture, surface: surface, active: active, serverFailure: serverFailure)
    }

    private func checkOutcome(
        _ fixture: ExecIntegrationFixture, surface: RelayTestSurface, active: UUID, serverFailure: Bool
    ) async throws {
        await fixture.socket.incoming.yield(Data([1, 65]))
        await fixture.socket.incoming.yield(Data([2, 66]))
        let status = serverFailure
            ? #"{"status":"Failure","reason":"InternalError","message":"Synthetic exec failure"}"#
            : #"{"status":"Failure","reason":"NonZeroExitCode","details":{"causes":[{"reason":"ExitCode","message":"37"}]}}"#
        await fixture.socket.incoming.yield(execStatus(status))
        try await sessionEventually { fixture.store.execSessions[1].state.isTerminal && surface.run.finished }
        #expect(try bridgeRead(surface.tty.controller, count: 2) == Data([65, 66]))
        #expect(try surface.run.wait() == (serverFailure ? .localFailure(.session) : .remoteExit(37)))
        #expect(try PTYSnapshot(surface.tty.terminal) == surface.tty.original)
        let authoritative = fixture.store.execSessions[1].state
        if serverFailure {
            let decoded = try JSONDecoder().decode(KubernetesStatus.self, from: Data(status.utf8))
            #expect(authoritative == .finished(.failed(.remote(decoded))))
            #expect(surface.run.diagnostic.contains(BridgeFailure.session.rawValue))
        } else { #expect(authoritative == .finished(.exited(code: 37))) }
        await fixture.actions.childTerminated(active)
        fixture.actions.closeShell(active)
        #expect(fixture.store.execSessions[1].state == authoritative)
        #expect(surface.closes == 1)
        try await transportEventually { fixture.directories.created.allSatisfy { !bridgeFileExists($0) } }
    }

    @Test func explicitSharedLoginCancelUnsubscribesAllPendingShellsWithoutCreatingListeners() async throws {
        let gate = TestGate()
        let process = FakeProcess { request, progress in
            if request.arguments == ["--version"] { return ProcessResult(stdout: Data("aws-cli/2.99".utf8), exitCode: 0) }
            progress("SYNTHETIC-INSTRUCTION")
            try await gate.wait()
            return ProcessResult(stdout: syntheticCredential, exitCode: 0)
        }
        let fixture = try ExecIntegrationFixture(process: process)
        defer { fixture.actions.shutdown() }
        let login = Task { try await fixture.actions.signIn(context: fixture.target.context) }
        defer { login.cancel() }
        try await sessionEventually { fixture.store.authenticationSessions.values.contains { !$0.instructions.isEmpty } }
        let id = try #require(fixture.store.authenticationSessions.values.first { !$0.instructions.isEmpty }?.id)
        _ = fixture.actions.openShell(target: fixture.target)
        _ = fixture.actions.openShell(target: fixture.target)
        try await transportEventually { await fixture.auth.waiterCount(operationID: id) == 3 }
        await fixture.actions.cancelAuthentication(operationID: id)
        await #expect(throws: CancellationError.self) { try await login.value }
        try await sessionEventually { fixture.store.execSessions.allSatisfy { $0.state.isTerminal } }
        #expect(fixture.store.execSessions.allSatisfy { $0.state == .finished(.cancelled) })
        #expect(fixture.store.authenticationSessions[id]?.instructions.isEmpty == true)
        #expect(fixture.directories.created.isEmpty)
        #expect(fixture.surfaces.created.isEmpty)
        #expect(await fixture.auth.waiterCount(operationID: id) == 0)
        #expect(await process.requests().count == 2)
    }

    @Test func coreActionsExposeSanitizedRuntimePreparationFailureAndUpdateRealResolver() async throws {
        let resolver = testResolver(files: Executables(paths: ["/selected/aws"]))
        let fixture = try ExecIntegrationFixture(process: FakeProcess(), resolver: resolver)
        defer { fixture.actions.shutdown() }
        let id = fixture.actions.openShell(target: fixture.target)
        try await sessionEventually { fixture.store.execSessions[0].state.isTerminal }
        guard case .finished(.failed(.authentication(let diagnostic))) = fixture.store.execSessions[0].state else {
            Issue.record("Expected authentication failure")
            return
        }
        #expect(diagnostic.contains("Configure Plugin Path"))
        #expect(fixture.directories.created.isEmpty)
        let settings = AuthSettings(executableOverrides: ["aws": "/selected/aws"])
        try await fixture.actions.updateAuthSettings(settings)
        #expect(try await resolver.settings() == settings)
        fixture.actions.retryShell(id)
        try await sessionEventually { fixture.surfaces.created[id] != nil }
        fixture.actions.closeShell(id)
        try await transportEventually { fixture.directories.created.allSatisfy { !bridgeFileExists($0) } }
        #expect(ProcessFailure.exited(17).authenticationDiagnostic.contains("17"))
    }
}

@MainActor private func sessionEventually(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw TestFailure.deadline }
        try await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor private final class ExecIntegrationFixture {
    let socket: ExecTestSocket
    let directories = BridgeDirectoryCapture()
    let surfaces = RelaySurfaceFactory()
    let session: ScriptedTransportSession
    let target: ExecTarget
    let auth: AuthenticationService
    let store: AppStore
    let actions: AppActions

    init(
        process: FakeProcess, resolver: PluginResolver = testResolver(),
        clock: any TransportClock = ContinuousTransportClock(), now: @escaping @Sendable () -> Date = { Date() },
        pingGate: TestGate? = nil
    ) throws {
        socket = ExecTestSocket(pingGate: pingGate)
        let context = try awsContext()
        target = try ExecTarget(context: context, namespace: "target-namespace", pod: "pod", container: "regular")
        let provider = CredentialProvider(resolver: resolver, runner: CredentialRunner(process: process), now: now)
        auth = AuthenticationService(provider: provider, login: AWSLoginService(runner: process))
        session = ScriptedTransportSession(socket: { [socket] _, _ in socket })
        let server = PTYBridgeServer(makeDirectory: { [directories] in try directories.create() })
        let exec = ExecService(transports: { [auth, session] context in
            try await URLSessionTransport(
                context: context, credentials: auth, factory: RecordingSessionFactory(session), clock: clock, warning: { _ in }
            )
        }, bridgeServer: server)
        store = try AppStore(contexts: [context, runtimeContext(user: nil, name: "other", server: "https://other.synthetic.invalid")])
        actions = AppActions(store: store, exec: exec, authentication: auth, surfaces: surfaces)
    }

    func checkAuthenticatedInputAndResize(_ surface: RelayTestSurface) async throws {
        let request = try #require(await session.socketRequests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-credential-only")
        #expect(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "v5.channel.k8s.io")
        #expect(request.url?.host == target.context.cluster.server.replacingOccurrences(of: "https://", with: ""))
        #expect(try RemoteCommandFrame(data: socket.sent[0]) == .resize(.init(columns: 80, rows: 24)))
        try bridgeWrite(surface.tty.controller, bytes: Data([3, 120]))
        try await transportEventually { self.socket.sent.contains { $0.first == 0 } }
        #expect(socket.sent.filter { $0.first == 0 }.reduce(Data()) { $0 + $1.dropFirst() } == Data([3, 120]))
        try surface.tty.resize(columns: 100, rows: 38)
        surface.run.control.resize()
        try await transportEventually {
            self.socket.sent.contains { (try? RemoteCommandFrame(data: $0)) == .resize(.init(columns: 100, rows: 38)) }
        }
    }
}

@MainActor private final class RelaySurfaceFactory: TerminalSurfaceCreating {
    var created: [UUID: RelayTestSurface] = [:]
    func makeSurface(
        sessionID: UUID, target: ExecTarget, endpoint: ExecBridgeEndpoint,
        onChildExit: @escaping @MainActor @Sendable () -> Void
    ) throws -> any TerminalSurface {
        let surface = try RelayTestSurface(endpoint: endpoint, onChildExit: onChildExit)
        created[sessionID] = surface
        return surface
    }
}

@MainActor private final class RelayTestSurface: TerminalSurface {
    let tty: TestPTY
    let run: BridgeTestRun
    let onChildExit: @MainActor @Sendable () -> Void
    var closes = 0
    init(endpoint: ExecBridgeEndpoint, onChildExit: @escaping @MainActor @Sendable () -> Void) throws {
        tty = try TestPTY()
        run = BridgeTestRun(child: PTYBridgeChild(), environment: endpoint.environment, input: tty.terminal, output: tty.terminal, tty: tty)
        self.onChildExit = onChildExit
    }
    func teardown() {
        closes += 1
        run.stop()
        onChildExit()
    }
}
