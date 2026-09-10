import Foundation
@testable import KubixCore
@testable import KubixRuntime
import Testing

@Suite @MainActor struct PodShellTransportTests {
    @Test func realDetailsAndExecShareTransportAndCancelFinalAuthenticationBeforeSocketOrAllocation() async throws {
        let context = try transportConfiguration().resolve()
        let credentials = PodShellTransportCredentials()
        let http = ScriptedTransportSession { _, _ in HTTPDataResponse(statusCode: 200, body: try podDetailsData()) }
        let transport = try await URLSessionTransport(
            context: context, credentials: credentials, factory: RecordingSessionFactory(http), warning: { _ in }
        )
        let bridge = try ExecTestBridge()
        let bridges = ExecTestBridges(bridge)
        let service = ExecService(transports: { received in #expect(received == context); return transport }, bridges: bridges)
        let store = AppStore(contexts: [context])
        let surfaces = PodShellSurfaces()
        let actions = AppActions(
            store: store, exec: service, authentication: PodShellAuth(), surfaces: surfaces,
            podDetails: PodDetailsService { received in #expect(received == context); return transport }
        )
        try actions.selectNamespace("team")
        let table = try JSONDecoder().decode(KubernetesTable.self, from: podPage())
        actions.applyPodUpdate(.init(rows: try table.rows.map { try PodRow(row: $0) }, columns: table.columnDefinitions, connection: .live))
        actions.openPodShell(uid: "uid-0")
        try await watchEventually { await credentials.gate.isWaiting }
        #expect(store.execSessions.first?.state == .connecting)
        #expect(await http.requests.count == 1)
        #expect(await http.requests.first?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(await http.socketRequests.isEmpty)
        #expect(await bridges.prepared.isEmpty)
        actions.selectPod(uid: nil)
        await credentials.gate.open()
        await actions.shutdownAndWait()
        #expect(await credentials.calls == 2)
        #expect(await http.socketRequests.isEmpty)
        #expect(await bridges.prepared.isEmpty)
        #expect(surfaces.created.isEmpty && store.execSessions[0].isClosed)
    }
}

private actor PodShellTransportCredentials: CredentialProviding {
    let gate = UncooperativeWatchGate()
    private(set) var calls = 0
    func acquire(for context: ResolvedContext, progress: @escaping AuthProgress) async throws -> AcquiredCredential {
        calls += 1
        if calls == 2 { await gate.wait() }
        return try AcquiredCredential(identity: CredentialIdentity(from: context), entry: nil)
    }
    func invalidate(_ identity: CredentialIdentity, failedGeneration: CredentialCache.Generation) {}
}
