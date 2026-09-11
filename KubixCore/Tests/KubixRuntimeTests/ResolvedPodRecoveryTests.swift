import Foundation
@testable import KubixCore
import KubixRuntime
import Testing

@Suite @MainActor struct ResolvedPodRecoveryTests {
    @Test(arguments: ["retry", "authenticate", "sign-in"], [APIError.podAuthentication, .watch(.credentialRefreshLimit), .http(code: 401, resource: "pods")])
    func providerResolvedRecoveryRestartsExactlyTheCommittedTarget(_ operation: String, _ failure: APIError) async throws {
        let count = InvocationCount()
        let process = FakeProcess { request, _ in
            if request.arguments == ["--version"] { return .init(stdout: Data("aws-cli/2.99".utf8), exitCode: 0) }
            if request.arguments.first == "sso" { return .init(stdout: Data(), exitCode: 0) }
            if await count.next() == 1 { return .init(stdout: Data(), exitCode: 17) }
            return .init(stdout: syntheticCredential, exitCode: 0)
        }
        let context = try awsContext()
        let settings = AuthSettings(searchDirectories: ["/extra"], executableOverrides: ["aws": "/tools/aws"])
        let (auth, _) = orchestration(process: process, resolver: testResolver(settings: settings, environment: ["CONFIG": "synthetic"]))
        let probe = RecoveryProbe()
        let store = AppStore(contexts: [context])
        let actions = AppActions(store: store, exec: PodShellExec(), authentication: auth, surfaces: PodShellSurfaces(), pods: probe)
        defer { actions.shutdown() }
        try await actions.updateAuthSettings(settings)
        try actions.selectNamespace("committed-team")
        actions.refreshPods()
        try await watchEventually { await probe.targets.count == 1 }
        await actions.authenticateSelectedContext()
        try await watchEventually { store.authenticationSessions.values.contains { $0.state == .failed } }
        let failed = try #require(store.authenticationSessions.values.first { $0.state == .failed })
        #expect(failed.credentialIdentity != (try CredentialIdentity(from: context)))
        actions.applyPodUpdate(.init(rows: [], columns: nil, connection: .failed(failure)))
        actions.setNamespaceInput("unfinished-draft")
        switch operation {
        case "retry": try await actions.retryAuthentication(operationID: failed.id)
        case "authenticate": await actions.authenticateSelectedContext()
        default: await actions.signInSelectedContext()
        }
        try await watchEventually { await probe.targets.count == 2 }
        #expect(await probe.targets.allSatisfy { $0.context == context && $0.namespace == "committed-team" })
        #expect(store.selectedNamespace == "committed-team" && store.namespaceDraft == "unfinished-draft")
        #expect(store.connection == .connecting && store.execSessions.isEmpty)
        #expect(await process.requests().filter { $0.arguments.contains("get-token") }.count == 2)
        await actions.shutdownAndWait()
        #expect(await probe.targets.count == 2)
    }

    @Test(arguments: ["context", "settings", "namespace", "away-back"])
    func lateResolvedAuthenticationCannotRestartChangedDiscovery(_ change: String) async throws {
        let gate = TestGate()
        let process = FakeProcess { _, _ in try await gate.wait(); return .init(stdout: syntheticCredential, exitCode: 0) }
        let first = try runtimeContext()
        let other = try runtimeContext(name: "other", server: "https://other.synthetic.invalid")
        let (auth, _) = orchestration(process: process, resolver: testResolver())
        let probe = RecoveryProbe()
        let store = AppStore(contexts: [first, other])
        let actions = AppActions(store: store, exec: PodShellExec(), authentication: auth, surfaces: PodShellSurfaces(), pods: probe)
        defer { actions.shutdown() }
        let work = Task { await actions.authenticateSelectedContext() }
        try await watchEventually { await process.requests().count == 1 }
        switch change {
        case "context": try actions.selectContext(named: "other")
        case "settings": try await actions.updateAuthSettings(.init(searchDirectories: ["/different"]))
        case "namespace": try actions.selectNamespace("new-team")
        default: try actions.selectContext(named: "other"); try actions.selectContext(named: first.name)
        }
        actions.applyPodUpdate(.init(rows: [], columns: nil, connection: .failed(.podAuthentication)))
        await gate.open()
        await work.value
        #expect(store.connection == .failed(.podAuthentication))
        await actions.shutdownAndWait()
        #expect(store.execSessions.isEmpty)
    }
}

private actor RecoveryProbe: PodWatching {
    struct Target: Sendable { let context: ResolvedContext; let namespace: String }
    private(set) var targets: [Target] = []
    func run(context: ResolvedContext, namespace: String, update: @escaping @MainActor @Sendable (PodWatchUpdate) -> Void) async {
        targets.append(Target(context: context, namespace: namespace))
    }
}
