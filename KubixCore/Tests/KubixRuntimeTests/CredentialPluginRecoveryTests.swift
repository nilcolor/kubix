import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Suite @MainActor struct CredentialPluginRecoveryTests {
    @Test func configuredPluginFailureThenExplicitRetryRestartsCommittedDiscoveryOnce() async throws {
        let count = InvocationCount()
        let process = FakeProcess { _, progress in
            if await count.next() == 1 {
                progress("https://synthetic.invalid/approval?code=PRIVATE-INSTRUCTION")
                return .init(stdout: Data("PRIVATE-CREDENTIAL-OUTPUT".utf8), exitCode: 17)
            }
            return .init(stdout: syntheticCredential, exitCode: 0)
        }
        let fixture = try await PluginRecoveryFixture(process: process)
        defer { fixture.actions.shutdown() }
        try fixture.start()
        try await watchEventually { fixture.failedSession != nil && fixture.store.connection.isFailed }
        let failed = try #require(fixture.failedSession)
        #expect(fixture.store.connection == .failed(.podAuthentication))
        #expect(failed.diagnostic == ProcessFailure.exited(17).errorDescription)
        #expect(failed.instructions.isEmpty && failed.authorizationURL == nil)
        #expect(failed.credentialIdentity != (try CredentialIdentity(from: fixture.context)))
        #expect(failed.credentialIdentity.belongs(to: fixture.context, settings: fixture.settings))
        #expect(await process.requests().count == 1)
        #expect(await fixture.session.requests.isEmpty)
        #expect(await fixture.session.streamRequests.isEmpty)
        #expect(fixture.clock.deadlines.isEmpty)
        fixture.actions.setNamespaceInput("unfinished-draft")

        try await fixture.actions.retryAuthentication(operationID: failed.id)
        try await watchEventually { fixture.store.connection == .live && fixture.stream.isWaiting }
        let acquired = try await fixture.provider.acquire(for: fixture.context)
        #expect(acquired.identity == failed.credentialIdentity)
        #expect(acquired.entry?.credential.token == "synthetic-credential-only")
        #expect(fixture.store.rows.map(\.id) == ["uid-0"])
        #expect(fixture.store.selectedNamespace == "committed-team" && fixture.store.namespaceDraft == "unfinished-draft")
        #expect(fixture.store.execSessions.isEmpty)
        #expect(fixture.capture.values.filter { $0.connection == .failed(.podAuthentication) }.count == 1)
        #expect(!String(reflecting: fixture.capture.values).contains("PRIVATE-"))
        #expect(await fixture.watcher.contexts == [fixture.context, fixture.context])
        #expect(await fixture.watcher.namespaces == ["committed-team", "committed-team"])
        let requests = await fixture.session.requests + fixture.session.streamRequests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.path == "/api/v1/namespaces/committed-team/pods" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-credential-only" })
        let plugins = await process.requests()
        #expect(plugins.count == 2)
        #expect(plugins.allSatisfy { $0.executable.path == "/tools/aws-vault" && $0.arguments == fixture.context.user?.exec?.args })
        #expect(plugins.allSatisfy { $0.environment["CONFIG"] == "synthetic" && $0.environment["PLUGIN_MODE"] == "configured" })
        await fixture.actions.shutdownAndWait()
        #expect(await fixture.watcher.contexts.count == 2)
        #expect(await process.requests().count == 2)
        #expect(fixture.stream.cancelled && fixture.clock.deadlines.isEmpty)
    }

    @Test(arguments: [ProcessFailure.invalidRequest, .launchFailed, .timedOut, .outputLimit, .pipeFailed])
    func credentialProcessErrorsStopAsAuthenticationFailures(_ failure: ProcessFailure) async throws {
        let process = FakeProcess { _, _ in throw failure }
        let fixture = try await PluginRecoveryFixture(process: process)
        defer { fixture.actions.shutdown() }
        try fixture.start()
        try await watchEventually { fixture.store.connection.isFailed }
        #expect(fixture.store.connection == .failed(.podAuthentication))
        #expect(await process.requests().count == 1)
        #expect(await fixture.session.requests.isEmpty)
        #expect(await fixture.session.streamRequests.isEmpty)
        #expect(fixture.clock.deadlines.isEmpty)
        await fixture.actions.shutdownAndWait()
    }

    @Test(arguments: [APIError.http(code: 403, resource: "pods in namespace committed-team"), .transport(.invalidResponse)])
    func successfulAuthenticationDoesNotRestartAPIOrTransportFailures(_ failure: APIError) async throws {
        let session = ScriptedTransportSession(data: { _, _ in
            if failure.httpCode == 403 { return .init(statusCode: 403, body: Data()) }
            throw failure
        })
        let fixture = try await PluginRecoveryFixture(process: FakeProcess(), session: session)
        defer { fixture.actions.shutdown() }
        try fixture.start()
        try await watchEventually { fixture.store.connection.isFailed && fixture.successfulSession != nil }
        let successful = try #require(fixture.successfulSession)
        #expect(fixture.store.connection == .failed(failure))
        try await fixture.actions.retryAuthentication(operationID: successful.id)
        #expect(fixture.store.connection == .failed(failure))
        await fixture.actions.shutdownAndWait()
        #expect(await fixture.watcher.contexts == [fixture.context])
        #expect(await session.requests.count == 1)
        #expect(await session.streamRequests.isEmpty)
        #expect(fixture.clock.deadlines.isEmpty)
    }

    @Test func missingConfiguredExecutableIsAuthenticationFailureBeforeProcessOrRequest() async throws {
        let context = try runtimeContext()
        let process = FakeProcess()
        let (authentication, _) = orchestration(
            process: process, resolver: testResolver(files: Executables(paths: []))
        )
        let session = ScriptedTransportSession()
        let transport = try await URLSessionTransport(
            context: context, credentials: authentication, factory: RecordingSessionFactory(session), warning: { _ in }
        )
        let capture = PodUpdateCapture()
        await WatchService(transports: { _ in transport }).run(kind: .pods, context: context, namespace: "team") { capture.values.append($0) }
        #expect(capture.values.last?.connection == .failed(.podAuthentication))
        #expect(await process.requests().isEmpty)
        #expect(await session.requests.isEmpty)
    }

    @Test func processErrorsOutsideCredentialAcquisitionAreNotTaggedAsAuthentication() async throws {
        let capture = PodUpdateCapture()
        let service = WatchService(transports: { _ in throw ProcessFailure.exited(17) })
        await service.run(kind: .pods, context: try runtimeContext(), namespace: "team") { capture.values.append($0) }
        #expect(capture.values.last?.connection == .failed(.transport(.invalidResponse)))
    }

    @Test(arguments: TransportEntry.allCases)
    func credentialCancellationRemainsCancellationAtEveryTransportEntry(_ entry: TransportEntry) async throws {
        let process = FakeProcess { _, _ in throw CancellationError() }
        let fixture = try await PluginRecoveryFixture(process: process)
        defer { fixture.actions.shutdown() }
        await #expect(throws: CancellationError.self) { try await entry.run(fixture.transport) }
        #expect(await fixture.session.requests.isEmpty)
        #expect(await fixture.session.streamRequests.isEmpty)
        #expect(await fixture.session.socketRequests.isEmpty)
        #expect(fixture.clock.deadlines.isEmpty)
        await fixture.actions.shutdownAndWait()
    }

    @Test func cancellingWatchDuringCredentialAcquisitionDoesNotPublishAuthenticationFailure() async throws {
        let gate = TestGate()
        let process = FakeProcess { _, _ in try await gate.wait(); return .init(stdout: syntheticCredential, exitCode: 0) }
        let fixture = try await PluginRecoveryFixture(process: process)
        defer { fixture.actions.shutdown() }
        try fixture.start()
        try await watchEventually { await process.requests().count == 1 }
        await fixture.actions.shutdownAndWait()
        #expect(!fixture.capture.values.contains { $0.connection.isFailed })
        #expect(await fixture.session.requests.isEmpty)
        #expect(await fixture.session.streamRequests.isEmpty)
        #expect(await process.requests().count == 1)
        #expect(fixture.clock.deadlines.isEmpty)
    }
}

@MainActor private final class PluginRecoveryFixture {
    let context: ResolvedContext
    let settings = AuthSettings(searchDirectories: ["/extra"], executableOverrides: ["aws-vault": "/tools/aws-vault"])
    let provider: CredentialProvider
    let session: ScriptedTransportSession
    let transport: URLSessionTransport
    let watcher: PluginRecoveryWatcher
    let store: AppStore
    let actions: AppActions
    let clock = ManualTransportClock()
    let stream = MemoryByteStream()
    let capture = PodUpdateCapture()

    var failedSession: AuthSession? { store.authenticationSessions.values.first { $0.state == .failed } }
    var successfulSession: AuthSession? { store.authenticationSessions.values.first { $0.state == .succeeded } }

    init(process: FakeProcess, session: ScriptedTransportSession? = nil) async throws {
        context = try runtimeContext(user: .init(exec: runtimeExec(
            command: "aws-vault", args: ["exec", "synthetic-profile", "--", "aws", "eks", "get-token", "--cluster-name", "synthetic"],
            env: [.init(name: "PLUGIN_MODE", value: "configured")]
        )))
        let (authentication, provider) = orchestration(process: process, resolver: testResolver(
            settings: settings, environment: ["CONFIG": "synthetic"], files: Executables(paths: ["/tools/aws-vault"])
        ))
        self.provider = provider
        let session = session ?? ScriptedTransportSession(
            data: { _, _ in .init(statusCode: 200, body: try podPage(namespace: "committed-team")) },
            stream: { [stream] _, _ in .init(statusCode: 200, body: stream) }
        )
        self.session = session
        transport = try await URLSessionTransport(
            context: context, credentials: authentication, factory: RecordingSessionFactory(session), clock: clock, warning: { _ in }
        )
        watcher = PluginRecoveryWatcher(
            service: WatchService(transports: { [transport, context] requested in
                #expect(requested == context)
                return transport
            }, clock: clock, jitter: { 1 }), capture: capture
        )
        store = AppStore(contexts: [context])
        actions = AppActions(
            store: store, exec: PodShellExec(), authentication: authentication, surfaces: PodShellSurfaces(), lists: watcher
        )
        try await actions.updateAuthSettings(settings)
    }

    func start() throws {
        try actions.selectNamespace("committed-team")
        actions.refreshList()
    }
}

private actor PluginRecoveryWatcher: ResourceWatching {
    let service: WatchService
    let capture: PodUpdateCapture
    private(set) var contexts: [ResolvedContext] = []
    private(set) var namespaces: [String] = []

    init(service: WatchService, capture: PodUpdateCapture) { self.service = service; self.capture = capture }

    func run(
        kind: ResourceKind, context: ResolvedContext, namespace: String,
        update: @escaping @MainActor @Sendable (ResourceListUpdate) -> Void
    ) async {
        contexts.append(context)
        namespaces.append(namespace)
        await service.run(kind: kind, context: context, namespace: namespace) { [capture] in
            capture.values.append($0)
            update($0)
        }
    }
}

private extension ListConnection {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
