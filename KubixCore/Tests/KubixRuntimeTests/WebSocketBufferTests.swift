import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Test func receivePumpPreservesBufferedOrderAndFinalFrameBeforeClose() async throws {
    let buffer = WebSocketReceiveBuffer()
    try buffer.append(Data([1, 65]))
    try buffer.append(Data([3, 66]))
    buffer.finish(APIError.transport(.closed))
    #expect(try await buffer.read(cancel: {}) == Data([1, 65]))
    #expect(try await buffer.read(cancel: {}) == Data([3, 66]))
    await #expect(throws: APIError.transport(.closed)) { try await buffer.read(cancel: {}) }
}

@Test func receivePumpHasByteAndMessageBoundsWithoutDroppingQueuedFrames() async throws {
    let bytes = WebSocketReceiveBuffer()
    try bytes.append(Data(repeating: 65, count: 1_048_576))
    #expect(throws: APIError.transport(.receiveBufferOverflow)) { try bytes.append(Data([66])) }
    #expect(try await bytes.read(cancel: {}).count == 1_048_576)
    #expect(throws: APIError.transport(.receiveBufferOverflow)) {
        try bytes.append(Data(repeating: 65, count: 1_048_577))
    }
    let messages = WebSocketReceiveBuffer()
    for _ in 0..<256 { try messages.append(Data()) }
    #expect(throws: APIError.transport(.receiveBufferOverflow)) { try messages.append(Data()) }
    #expect(try await messages.read(cancel: {}).isEmpty)
    try messages.append(Data([1]))
}

@Test func pendingNativeOperationsAreCompletedByCloseNotFoundationCallbacks() async throws {
    let calls = WebSocketPendingCalls()
    let promise = TransportPromise<Void>()
    let id = try calls.add { promise.finish(.failure($0)) }
    let work = Task { try await promise.value(cancel: {}) }
    calls.finish(CancellationError())
    await #expect(throws: CancellationError.self) { try await work.value }
    #expect(throws: CancellationError.self) { try calls.add { _ in } }
    calls.remove(id)
    promise.finish(.success(()))
}

@Test func explicitNativeCloseDiscardsBufferedMessages() async throws {
    let buffer = WebSocketReceiveBuffer()
    try buffer.append(Data([65]))
    buffer.finish(CancellationError(), discardBuffered: true)
    await #expect(throws: CancellationError.self) { try await buffer.read(cancel: {}) }
}
