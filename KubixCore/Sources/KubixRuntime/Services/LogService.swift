import Foundation
import KubixCore

public struct LogService: LogStreaming {
    public typealias TransportFactory = @Sendable (ResolvedContext) async throws -> any Transport
    private let transports: TransportFactory
    public static let maximumChunkBytes = 65_536
    public static let maximumBatchLines = 64

    public init(transports: @escaping TransportFactory) { self.transports = transports }

    public func run(
        target: LogTarget, request: LogRequest,
        receive: @escaping @MainActor @Sendable (LogEvent) -> Void
    ) async -> LogOutcome {
        var decoder = LogLineDecoder()
        var opened = false
        do {
            try Task.checkCancellation()
            try validate(target: target, request: request)
            let transport = try await transports(target.context)
            try Task.checkCancellation()
            let stream = try await transport.stream(for: request.request, purpose: request.purpose)
            defer { stream.cancel() }
            try Task.checkCancellation()
            opened = true
            await receive(.opened)
            try await withTaskCancellationHandler {
                while let chunk = try await stream.read() {
                    try Task.checkCancellation()
                    guard chunk.count <= Self.maximumChunkBytes else { throw APIError.transport(.receiveBufferOverflow) }
                    var batch: [DecodedLogLine] = []
                    for byte in chunk {
                        if let line = decoder.consume(byte) { batch.append(line) }
                        if batch.count == Self.maximumBatchLines {
                            await receive(.lines(batch))
                            batch.removeAll(keepingCapacity: true)
                            try Task.checkCancellation()
                        }
                    }
                    if !batch.isEmpty { await receive(.lines(batch)) }
                }
                try Task.checkCancellation()
            } onCancel: { stream.cancel() }
            if let last = decoder.finish() { await receive(.lines([last])) }
            return .completed
        } catch {
            if let last = decoder.finish() { await receive(.lines([last])) }
            if Task.isCancelled { return .cancelled }
            let normalized = transportError(error)
            let failure = normalized is CancellationError ? LogFailure.transport : LogFailure.classify(normalized)
            return opened ? .interrupted(failure) : .failed(failure)
        }
    }

    private func validate(target: LogTarget, request: LogRequest) throws {
        let expected = try LogRequest(namespace: target.namespace, pod: target.pod, container: target.container.name)
        guard !target.uid.isEmpty, request.request.path == expected.request.path,
              request.request.query.first(where: { $0.name == "container" })?.value == target.container.name else { throw APIError.invalidRequest }
    }
}
