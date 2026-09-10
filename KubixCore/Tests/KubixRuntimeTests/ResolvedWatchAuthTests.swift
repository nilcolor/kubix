import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Suite @MainActor struct ResolvedWatchAuthTests {
    @Test(arguments: ["list", "stream-open", "in-stream", "repeated"])
    func resolvedExecIdentityRefreshesAndRecoversWithOneBudget(_ failure: String) async throws {
        let context = try runtimeContext()
        let process = FakeProcess()
        let settings = AuthSettings(searchDirectories: ["/extra"], executableOverrides: ["plugin": "/tools/plugin"])
        let provider = CredentialProvider(
            resolver: testResolver(settings: settings, environment: ["CONFIG": "synthetic"]),
            runner: CredentialRunner(process: process)
        )
        let original = try await provider.acquire(for: context)
        #expect(original.identity != (try CredentialIdentity(from: context)))
        #expect(original.identity.belongs(to: context, settings: settings))
        let goodStream = MemoryByteStream([try podEvent("ADDED", id: 1, version: "recovered")])
        let session = ScriptedTransportSession(data: { _, call in
            HTTPDataResponse(statusCode: failure == "list" && call == 1 ? 401 : 200, body: try podPage())
        }, stream: { _, call in
            if failure == "stream-open", call == 1 {
                return HTTPStreamResponse(statusCode: 401, body: MemoryByteStream())
            }
            if (failure == "in-stream" && call == 1) || failure == "repeated" {
                return HTTPStreamResponse(statusCode: 200, body: MemoryByteStream([podStatus(401)]))
            }
            return HTTPStreamResponse(statusCode: 200, body: goodStream)
        })
        let clock = ManualTransportClock()
        let transport = try await URLSessionTransport(
            context: context, credentials: provider, factory: RecordingSessionFactory(session), clock: clock, warning: { _ in }
        )
        let owner = try WatchTestOwner(transport: transport, clock: clock)
        defer { owner.actions.shutdown() }
        owner.start()
        if failure == "repeated" {
            try await watchEventually { owner.store.connection == .failed(.watch(.credentialRefreshLimit)) }
        } else {
            try await watchEventually { owner.store.rows.map(\.id) == ["uid-0", "uid-1"] }
            #expect(owner.store.connection == .live)
        }
        let replacement = try await provider.acquire(for: context)
        #expect(replacement.identity == original.identity)
        #expect(replacement.entry?.generation != original.entry?.generation)
        #expect(await process.requests().count == 2)
        #expect(await session.requests.count == (failure == "list" ? 2 : 1))
        #expect(await session.streamRequests.count == (failure == "list" ? 1 : 2))
        await owner.stop()
        #expect(clock.deadlines.isEmpty)
    }

    @Test(arguments: [true, false])
    func resolvedReceiptsAreOwnerBoundAndNeverInvalidateNewerGeneration(exec: Bool) async throws {
        let context = try runtimeContext(user: exec ? .init(exec: runtimeExec()) : .init(token: "synthetic"))
        let process = FakeProcess()
        let provider = CredentialProvider(
            resolver: testResolver(settings: .init(searchDirectories: ["/custom"]), environment: ["CONFIG": "synthetic"]),
            runner: CredentialRunner(process: process)
        )
        let original = try await provider.acquire(for: context)
        let generation = try #require(original.entry?.generation)
        let session = ScriptedTransportSession(stream: { _, _ in .init(statusCode: 200, body: MemoryByteStream()) })
        let transport = try await URLSessionTransport(
            context: context, credentials: provider, factory: RecordingSessionFactory(session), warning: { _ in }
        )
        let foreignTransport = try await URLSessionTransport(
            context: context, credentials: provider, factory: RecordingSessionFactory(session), warning: { _ in }
        )
        let stream = try await transport.stream(for: podsRequest, purpose: .watch)
        defer { stream.cancel() }
        let receipt = stream.credentialRejection(.http(code: 401, resource: "pods watch"))
        await #expect(throws: APIError.credentialsExhausted(receipt)) {
            try await foreignTransport.invalidateCredentials(after: receipt)
        }
        let unchanged = try await provider.acquire(for: context)
        #expect(unchanged.entry?.generation == generation)
        await provider.invalidate(original.identity, failedGeneration: generation)
        let replacement = try await provider.acquire(for: context)
        try await transport.invalidateCredentials(after: receipt)
        let retained = try await provider.acquire(for: context)
        #expect(retained.entry?.generation == replacement.entry?.generation)
        #expect(retained.entry?.generation != generation)
        #expect(await process.requests().count == (exec ? 2 : 0))
    }
}
