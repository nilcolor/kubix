import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

struct WatchTransportAuthTests {
    @Test func managedHTTP401ReturnsReceiptWithoutRetryButDefaultRequestsStillRetry() async throws {
        let credentials = TransportCredentials()
        let session = ScriptedTransportSession(data: { _, _ in HTTPDataResponse(statusCode: 401, body: Data()) })
        let transport = try await testTransport(session: session, credentials: credentials)
        let request = APIRequest(resource: "pods", namespace: "team", managesCredentialRefresh: true)
        let rejected: APIError
        do {
            _ = try await transport.data(for: request)
            throw TestFailure.missingFixture
        } catch let error as APIError { rejected = error }
        #expect(rejected.httpCode == 401 && !rejected.credentialRefreshExhausted)
        #expect(await credentials.acquisitions == 1)
        #expect(await credentials.invalidations.isEmpty)
        try await transport.invalidateCredentials(after: rejected)
        #expect(await credentials.acceptedInvalidations == 1)
        do {
            _ = try await transport.data(for: podsRequest)
            Issue.record("Expected a bounded exhausted 401.")
        } catch let error as APIError {
            #expect(error.httpCode == 401 && error.credentialRefreshExhausted)
        }
        #expect(await session.requests.count == 3)
        #expect(await credentials.acceptedInvalidations == 2)
    }

    @Test func inStreamReceiptInvalidatesOnlyItsFailedGenerationNotANewerAcquisition() async throws {
        let context = try transportConfiguration().resolve()
        let credentials = TransportCredentials()
        let acquired = try await credentials.acquire(for: context)
        let original = try #require(acquired.entry)
        let stream = MemoryByteStream()
        let session = ScriptedTransportSession(stream: { _, _ in HTTPStreamResponse(statusCode: 200, body: stream) })
        let transport = try await testTransport(session: session, credentials: credentials)
        let opened = try await transport.stream(
            for: APIRequest(resource: "pods", namespace: "team", managesCredentialRefresh: true), purpose: .watch
        )
        defer { opened.cancel() }
        await credentials.invalidate(acquired.identity, failedGeneration: original.generation)
        let replacement = try await credentials.acquire(for: context)
        #expect(replacement.entry?.generation != original.generation)
        let rejection = opened.credentialRejection(.http(code: 401, resource: "pods watch"))
        try await transport.invalidateCredentials(after: rejection)
        #expect(await credentials.invalidations == [original.generation, original.generation])
        #expect(await credentials.acceptedInvalidations == 1)
        let retained = try await credentials.acquire(for: context)
        #expect(retained.entry?.generation == replacement.entry?.generation)
        #expect(opened.credentialRejection(.http(code: 403, resource: "pods")) == .http(code: 403, resource: "pods"))
    }

    @Test @MainActor func realWatchStoreAndManagedTransportShareOneAuthBudgetAcrossPagesAndStreamOpen() async throws {
        let credentials = TransportCredentials()
        let session = ScriptedTransportSession(
            data: { _, call in
                call == 1 ? HTTPDataResponse(statusCode: 401, body: Data()) : HTTPDataResponse(statusCode: 200, body: try podPage())
            }, stream: { _, _ in HTTPStreamResponse(statusCode: 401, body: MemoryByteStream()) }
        )
        let clock = ManualTransportClock()
        let transport = try await testTransport(session: session, credentials: credentials, clock: clock)
        let owner = try WatchTestOwner(transport: transport, clock: clock)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { owner.store.connection == .failed(.watch(.credentialRefreshLimit)) }
        #expect(await credentials.acceptedInvalidations == 1)
        #expect(await session.requests.count == 2)
        #expect(await session.streamRequests.count == 1)
        #expect(owner.store.rows.count == 1)
        await owner.stop()
        #expect(clock.deadlines.isEmpty)
    }

    @Test @MainActor func realInStreamUnauthorizedRefreshesOnceAndCannotLoopAfterAnEvent() async throws {
        let credentials = TransportCredentials()
        let session = ScriptedTransportSession(
            data: { _, _ in HTTPDataResponse(statusCode: 200, body: try podPage()) },
            stream: { _, _ in HTTPStreamResponse(statusCode: 200, body: MemoryByteStream([try podEvent(), podStatus(401)])) }
        )
        let clock = ManualTransportClock()
        let transport = try await testTransport(session: session, credentials: credentials, clock: clock)
        let owner = try WatchTestOwner(transport: transport, clock: clock)
        defer { owner.actions.shutdown() }
        owner.start()
        try await watchEventually { owner.store.connection == .failed(.watch(.credentialRefreshLimit)) }
        #expect(await credentials.acceptedInvalidations == 1)
        #expect(await session.streamRequests.count == 2)
        await owner.stop()
        #expect(clock.deadlines.isEmpty)
    }

    @Test func receiptPreservesSafeErrorMetadataAndRejectsMissingOrForeignReceipt() async throws {
        let context = try transportConfiguration().resolve()
        let credentials = TransportCredentials()
        let acquired = try await credentials.acquire(for: context)
        let entry = try #require(acquired.entry)
        let base = APIError.retryAfter(.credentialsExhausted(.http(code: 401, resource: "pods")), delay: 7)
        let receipt = APIError.credentialRejected(base, identity: acquired.identity, generation: entry.generation)
        #expect(receipt.httpCode == 401 && receipt.retryAfterDelay == 7 && receipt.credentialRefreshExhausted)
        #expect(receipt.description == base.description)
        let transport = try await testTransport(session: ScriptedTransportSession(), credentials: credentials)
        await #expect(throws: APIError.credentialsExhausted(base)) { try await transport.invalidateCredentials(after: base) }
        let other = try CredentialIdentity(from: runtimeContext(user: nil, server: "https://other.synthetic.invalid"))
        let foreign = APIError.credentialRejected(base, identity: other, generation: entry.generation)
        await #expect(throws: APIError.credentialsExhausted(foreign)) { try await transport.invalidateCredentials(after: foreign) }
        #expect(await credentials.invalidations.isEmpty)
    }
}
