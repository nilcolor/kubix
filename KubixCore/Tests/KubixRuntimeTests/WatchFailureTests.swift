import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Suite @MainActor struct WatchFailureTests {
    @Test func expirationExhaustionStillClearsTheUnresumableSnapshot() async throws {
        let transport = WatchTestTransport(stream: { _, _ in MemoryByteStream([podStatus(410)]) })
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { owner.store.connection == .failed(.watch(.retryLimit)) }
        #expect(await transport.requests.count == 7)
        #expect(await transport.streams.count == 7)
        #expect(owner.store.rows.isEmpty && owner.store.columns == nil)
        await owner.stop()
        #expect(owner.clock.deadlines.isEmpty)
    }

    @Test func HTTPGoneWhileOpeningWatchRepaginatesBeforeRetryingWatch() async throws {
        let gate = TestGate()
        let transport = WatchTestTransport(data: { _, call in
            if call > 1 { try await gate.wait() }
            return try podPage(ids: [call], version: "list-\(call)")
        }, stream: { _, call in
            if call == 1 { throw APIError.http(code: 410, resource: "pods") }
            return MemoryByteStream()
        })
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { await transport.requests.count == 2 }
        #expect(owner.store.rows.isEmpty && owner.store.columns == nil && owner.store.connection == .connecting)
        #expect(owner.capture.values.allSatisfy { $0.connection != .live })
        await gate.open()
        try await watchEventually { owner.store.connection == .live }
        #expect(owner.store.rows.map(\.id) == ["uid-2"])
        #expect(await transport.streams.map { podQuery($0)["resourceVersion"] } == ["list-1", "list-2"])
        await owner.stop()
    }

    @Test(arguments: [403, 404])
    func forbiddenAndMissingNamespaceNeverFallbackOrListNamespaces(_ code: Int) async throws {
        let transport = WatchTestTransport { request, _ in
            #expect(request.path == ["api", "v1", "namespaces", "known-restricted", "pods"])
            throw APIError.http(code: code, resource: "pods")
        }
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        for draft in ["k", "known-", "known-restricted", "../bad", "UPPER"] { owner.actions.setNamespaceInput(draft) }
        #expect(!owner.actions.commitNamespaceInput())
        #expect(owner.store.selectedNamespace == "team" && owner.store.namespaceDraft == "UPPER")
        #expect(owner.store.namespaceDiagnostic != nil && owner.store.connection == .idle)
        #expect(await transport.requests.isEmpty)
        owner.actions.setNamespaceInput("known-restricted")
        #expect(owner.actions.commitNamespaceInput())
        owner.start()
        try await watchEventually { owner.store.connection == .failed(.http(code: code, resource: "pods")) }
        #expect(owner.store.selectedNamespace == "known-restricted")
        #expect(await transport.requests.count == 1)
        #expect(await transport.streams.isEmpty)
        #expect(owner.store.namespaces == ["team", "known-restricted"])
        await owner.stop()
    }

    @Test(arguments: [false, true])
    func unauthorizedBudgetSpansListAndWatchAndExhaustedTransportIsNotRefreshed(_ exhausted: Bool) async throws {
        let error = APIError.http(code: 401, resource: "pods")
        let transport = WatchTestTransport(data: { _, call in
            if call == 1 { throw exhausted ? APIError.credentialsExhausted(error) : error }
            return try podPage()
        }, stream: { _, _ in MemoryByteStream([podStatus(401)]) })
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { owner.store.connection == .failed(.watch(.credentialRefreshLimit)) }
        #expect(await transport.invalidations.count == (exhausted ? 0 : 1))
        #expect(await transport.requests.count == (exhausted ? 1 : 2))
        await owner.stop()
    }

    @Test func successfulEventsDoNotResetTheInStream401Budget() async throws {
        let data = try podEvent()
        let transport = WatchTestTransport(stream: { _, _ in MemoryByteStream([data, podStatus(401)]) })
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { owner.store.connection == .failed(.watch(.credentialRefreshLimit)) }
        #expect(await transport.invalidations.count == 1)
        #expect(await transport.streams.count == 2)
        #expect(owner.store.rows.count == 1)
        await owner.stop()
    }

    @Test func normalLeaseResetsCredentialRefreshBudget() async throws {
        let healthy = MemoryByteStream()
        let final = MemoryByteStream()
        let transport = WatchTestTransport(stream: { _, call in
            switch call {
            case 1, 3: return MemoryByteStream([podStatus(401)])
            case 2: return healthy
            default: return final
            }
        })
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { healthy.isWaiting }
        owner.clock.advance(to: 300)
        healthy.yield(nil)
        try await watchEventually { final.isWaiting }
        #expect(await transport.invalidations.count == 2)
        #expect(await transport.streams.count == 4)
        #expect(owner.store.connection == .live)
        await owner.stop()
    }

    @Test(arguments: [429, 500, 503])
    func transientListErrorsHonorRetryAfterAndStopAtSharedRetryLimit(_ code: Int) async throws {
        let transport = WatchTestTransport { _, _ in
            throw APIError.retryAfter(.http(code: code, resource: "pods"), delay: 45)
        }
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        for attempt in 1...6 {
            let deadline = Double(attempt * 45)
            try await watchEventually { owner.clock.deadlines == [deadline] }
            #expect(await transport.requests.count == attempt)
            #expect(owner.store.connection == .connecting && owner.store.rows.isEmpty)
            owner.clock.advance(to: deadline)
        }
        try await watchEventually { owner.store.connection == .failed(.watch(.retryLimit)) }
        #expect(await transport.requests.count == 7)
        #expect(await transport.streams.isEmpty)
        await owner.stop()
    }

    @Test(arguments: [403, 404, 429, 503])
    func streamStatusUsesStateSpecificDecisions(_ code: Int) async throws {
        let transport = WatchTestTransport(stream: { _, _ in MemoryByteStream([podStatus(code)]) })
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        if code == 429 || code == 503 {
            try await watchEventually { owner.clock.deadlines == [1] }
            #expect(owner.store.connection == .connecting)
        } else {
            try await watchEventually {
                if case .failed(let error) = owner.store.connection { return error.httpCode == code }
                return false
            }
            #expect(owner.clock.deadlines.isEmpty)
        }
        #expect(owner.store.rows.count == 1)
        #expect(await transport.requests.count == 1)
        #expect(await transport.streams.count == 1)
        await owner.stop()
    }

    @Test(arguments: [false, true])
    func parseFailurePreservesValidPrefixButIsTerminal(_ truncated: Bool) async throws {
        var bytes = try podEvent(id: 4)
        bytes.append(Data((truncated ? "{\"type\":" : "invalid-json\n").utf8))
        let stream = MemoryByteStream([bytes], finished: true)
        let transport = WatchTestTransport(stream: { _, _ in stream })
        let owner = try WatchTestOwner(transport: transport)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually {
            owner.store.connection == .failed(.watch(.decoding(truncated ? .truncatedEOF : .malformedEvent)))
        }
        #expect(owner.store.rows.map(\.id) == ["uid-0", "uid-4"])
        #expect(stream.cancelled && owner.clock.deadlines.isEmpty)
        #expect(await transport.streams.count == 1)
        await owner.stop()
    }
}
