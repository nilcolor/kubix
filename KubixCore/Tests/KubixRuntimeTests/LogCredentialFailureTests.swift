import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Suite @MainActor struct LogCredentialFailureTests {
    @Test func configuredPluginFailureOffersSharedAuthRecoveryWithoutLeakingPayloads() async throws {
        let count = InvocationCount()
        let process = FakeProcess { _, progress in
            if await count.next() == 1 {
                progress("https://synthetic.invalid/approve?code=PRIVATE-INSTRUCTION")
                return .init(stdout: Data("PRIVATE-CREDENTIAL-OUTPUT".utf8), exitCode: 17)
            }
            return .init(stdout: syntheticCredential, exitCode: 0)
        }
        let fixture = try await LogCredentialFixture(process: process)
        let sessions = SessionCapture()
        let observer = observe(fixture.authentication, in: sessions)
        defer { observer.cancel() }
        let failure = await fixture.run()
        #expect(failure == .failed(.authentication))
        #expect(!fixture.capture.opened && fixture.capture.lines.isEmpty)
        #expect(await fixture.session.streamRequests.isEmpty && fixture.clock.deadlines.isEmpty)
        try await eventually { sessions.values.last?.state == .failed }
        let terminal = try #require(sessions.values.last)
        #expect(terminal.instructions.isEmpty && terminal.authorizationURL == nil)
        #expect(terminal.diagnostic == ProcessFailure.exited(17).authenticationDiagnostic)
        #expect(!String(reflecting: failure).contains("PRIVATE-"))
        #expect(!LogFailure.authentication.diagnostic.contains("PRIVATE-"))
        #expect(LogFailure.authentication.diagnostic.contains("shared authentication controls"))

        _ = try await fixture.authentication.retry(operationID: terminal.id)
        #expect(await fixture.run() == .completed)
        #expect(fixture.capture.opened && fixture.capture.lines.map(\.text) == ["synthetic log line"])
        let requests = await process.requests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy {
            $0.executable.path == "/tools/aws-vault" && $0.arguments == fixture.context.user?.exec?.args
                && $0.environment["PLUGIN_MODE"] == "configured"
        })
        #expect(await fixture.session.streamRequests.count == 1)
        #expect(await fixture.session.streamRequests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-credential-only")
        await fixture.authentication.shutdown()
        await observer.value
        #expect(fixture.clock.deadlines.isEmpty)
    }

    @Test(arguments: [ProcessFailure.invalidRequest, .launchFailed, .timedOut, .outputLimit, .pipeFailed])
    func acquisitionFailuresRemainAuthenticationNotLogTransport(_ failure: ProcessFailure) async throws {
        let fixture = try await LogCredentialFixture(process: FakeProcess { _, _ in throw failure })
        #expect(await fixture.run() == .failed(.authentication))
        #expect(await fixture.session.streamRequests.isEmpty && fixture.clock.deadlines.isEmpty)
        #expect(!fixture.capture.opened && fixture.capture.lines.isEmpty)
        await fixture.authentication.shutdown()
    }

    @Test func missingExecutableFailsAsAuthenticationBeforeProcessAndHTTP() async throws {
        let process = FakeProcess()
        let fixture = try await LogCredentialFixture(process: process, executablePresent: false)
        #expect(await fixture.run() == .failed(.authentication))
        #expect(await process.requests().isEmpty)
        #expect(await fixture.session.streamRequests.isEmpty)
        await fixture.authentication.shutdown()
    }

    @Test(arguments: LogBoundaryControl.allCases)
    func authenticatedHTTPFailuresKeepTheirOriginAndDiscardRawDiagnostics(_ control: LogBoundaryControl) async throws {
        let session = ScriptedTransportSession(stream: { _, _ in
            switch control {
            case .forbidden:
                return .init(statusCode: 403, body: MemoryByteStream([Data("""
                {"kind":"Status","reason":"Forbidden","message":"PRIVATE-STATUS synthetic-credential-only"}
                """.utf8)], finished: true))
            case .process: throw ProcessFailure.exited(17)
            case .raw: throw NSError(domain: "synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: "PRIVATE-PROVIDER-TEXT"])
            case .deadline: throw URLError(.timedOut)
            case .cancelled: throw CancellationError()
            }
        })
        let fixture = try await LogCredentialFixture(process: FakeProcess(), session: session)
        let outcome = await fixture.run()
        #expect(outcome == .failed(control.expected))
        #expect(!String(reflecting: outcome).contains("PRIVATE-"))
        #expect(!fixture.capture.opened && fixture.capture.lines.isEmpty)
        #expect(await session.streamRequests.count == 1)
        #expect(fixture.clock.deadlines.isEmpty)
        await fixture.authentication.shutdown()
    }

    @Test func processFailureOutsideAcquisitionIsNotAuthentication() async throws {
        let fixture = try await LogCredentialFixture(process: FakeProcess())
        let service = LogService { _ in throw ProcessFailure.exited(17) }
        #expect(await service.run(target: fixture.target, request: fixture.request, receive: { _ in }) == .failed(.transport))
        await fixture.authentication.shutdown()
    }

    @Test(arguments: [true, false])
    func realProviderCancellationDoesNotBecomeAnAuthenticationFailure(requesterCancelled: Bool) async throws {
        let gate = TestGate()
        let process = FakeProcess { _, _ in
            if requesterCancelled { try await gate.wait() }
            throw CancellationError()
        }
        let fixture = try await LogCredentialFixture(process: process)
        let task = Task { await fixture.run() }
        defer { task.cancel() }
        try await eventually { await process.requests().count == 1 }
        if requesterCancelled { task.cancel() }
        #expect(await task.value == (requesterCancelled ? .cancelled : .failed(.transport)))
        #expect(await fixture.session.streamRequests.isEmpty)
        #expect(!fixture.capture.opened && fixture.capture.lines.isEmpty)
        #expect(fixture.clock.deadlines.isEmpty)
        await fixture.authentication.shutdown()
    }
}

enum LogBoundaryControl: CaseIterable, Sendable {
    case forbidden, process, raw, deadline, cancelled
    var expected: LogFailure {
        switch self {
        case .forbidden: .forbidden
        case .deadline: .deadline
        default: .transport
        }
    }
}

@MainActor private final class LogCredentialFixture {
    let context: ResolvedContext
    let target: LogTarget
    let request: LogRequest
    let authentication: AuthenticationService
    let session: ScriptedTransportSession
    let service: LogService
    let clock = ManualTransportClock()
    let capture = LogCapture()

    init(process: FakeProcess, executablePresent: Bool = true, session: ScriptedTransportSession? = nil) async throws {
        context = try runtimeContext(user: .init(exec: runtimeExec(
            command: "aws-vault", args: ["exec", "synthetic-profile", "--", "aws", "eks", "get-token", "--cluster-name", "synthetic"],
            env: [.init(name: "PLUGIN_MODE", value: "configured")]
        )))
        let details = try JSONDecoder().decode(PodDetails.self, from: podDetailsData())
        target = try LogTarget(context: context, details: details, container: #require(details.containers.first))
        request = try LogRequest(namespace: target.namespace, pod: target.pod, container: target.container.name)
        (authentication, _) = orchestration(process: process, resolver: testResolver(
            files: Executables(paths: executablePresent ? ["/tools/aws-vault"] : [])
        ))
        let session = session ?? ScriptedTransportSession(stream: { _, _ in
            .init(statusCode: 200, body: MemoryByteStream([Data("synthetic log line\n".utf8)], finished: true))
        })
        self.session = session
        let transport = try await URLSessionTransport(
            context: context, credentials: authentication, factory: RecordingSessionFactory(session), clock: clock, warning: { _ in }
        )
        service = LogService { _ in transport }
    }

    func run() async -> LogOutcome {
        await service.run(target: target, request: request) { self.capture.receive($0) }
    }
}
