import Foundation
import KubixCore
import KubixRuntime
import Testing

actor LogTestTransport: Transport {
    typealias DataHandler = @Sendable (APIRequest, Int) async throws -> Data
    typealias StreamHandler = @Sendable (APIRequest, Int) async throws -> any HTTPByteStream
    let onData: DataHandler
    let onStream: StreamHandler
    private(set) var requests: [APIRequest] = []
    private(set) var streams: [APIRequest] = []
    private(set) var purposes: [TransportPurpose] = []

    init(data: @escaping DataHandler = { _, _ in try podDetailsData() }, stream: @escaping StreamHandler = { _, _ in MemoryByteStream() }) {
        onData = data
        onStream = stream
    }
    func data(for request: APIRequest) async throws -> Data {
        requests.append(request)
        return try await onData(request, requests.count)
    }
    func stream(for request: APIRequest, purpose: TransportPurpose) async throws -> any HTTPByteStream {
        streams.append(request)
        purposes.append(purpose)
        return try await onStream(request, streams.count)
    }
    func webSocket(for request: APIRequest) throws -> any WebSocketConnection { throw APIError.invalidRequest }
}
