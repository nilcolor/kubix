import Foundation
import KubixCore

public final class URLSessionWebSocketConnection: WebSocketConnection, Sendable {
    public let negotiatedProtocol: String?
    private let task: URLSessionWebSocketTask
    private let incoming = WebSocketReceiveBuffer()
    private let pending = WebSocketPendingCalls()

    private init(task: URLSessionWebSocketTask, negotiatedProtocol: String?) {
        self.task = task
        self.negotiatedProtocol = negotiatedProtocol
        receiveNext()
    }

    static func connect(
        session: URLSession, request: URLRequest, trust: ClusterTrustPolicy
    ) async throws -> URLSessionWebSocketConnection {
        try Task.checkCancellation()
        let delegate = WebSocketUpgradeDelegate(policy: trust)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1_048_576
        task.delegate = delegate
        task.resume()
        do {
            let selected = try await delegate.upgrade.value { task.cancel(with: .goingAway, reason: nil) }
            try Task.checkCancellation()
            return URLSessionWebSocketConnection(task: task, negotiatedProtocol: selected)
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            throw error
        }
    }

    public func send(_ data: Data) async throws {
        try Task.checkCancellation()
        let completion = TransportPromise<Void>()
        let id = try pending.add { completion.finish(.failure($0)) }
        defer { pending.remove(id) }
        task.send(.data(data)) { error in
            completion.finish(error.map { .failure(transportError($0)) } ?? .success(()))
        }
        try await completion.value(cancel: cancel)
    }

    public func receive() async throws -> Data {
        try await incoming.read(cancel: cancel)
    }

    public func ping() async throws {
        try Task.checkCancellation()
        let completion = TransportPromise<Void>()
        let id = try pending.add { completion.finish(.failure($0)) }
        defer { pending.remove(id) }
        task.sendPing { error in
            completion.finish(error == nil ? .success(()) : .failure(APIError.transport(.pingFailed)))
        }
        try await completion.value(cancel: cancel)
    }

    private func receiveNext() {
        // Foundation may not process pong callbacks without a pending receive. Pump separately
        // from the consumer, with a hard buffer cap; overflow fails visibly rather than dropping
        // exec data or allowing backpressure to starve control frames indefinitely.
        task.receive { [weak self] result in
            guard let self else { return }
            do {
                switch result {
                case .success(.data(let data)): try incoming.append(data)
                case .success: throw APIError.transport(.nonBinaryMessage)
                case .failure(let error): throw transportError(error)
                }
                receiveNext()
            } catch { terminate(error) }
        }
    }

    private func terminate(_ error: any Error) {
        incoming.finish(error, discardBuffered: error is CancellationError)
        pending.finish(error)
        task.cancel(with: .goingAway, reason: nil)
    }

    public func cancel() { terminate(CancellationError()) }
    deinit { terminate(CancellationError()) }
}

final class WebSocketUpgradeDelegate: ClusterTrustDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    let upgrade = TransportPromise<String?>()
    private let state = NSLock()
    private var opened = false

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        state.withLock { opened = true }
        upgrade.finish(.success(`protocol`))
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        upgrade.finish(.failure(APIError.transport(.closed)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard !state.withLock({ opened }) else { return }
        upgrade.finish(.failure(authenticationFailure ?? Self.failure(response: task.response, error: error)))
    }

    static func failure(response: URLResponse?, error: (any Error)?) -> any Error {
        if let response = response as? HTTPURLResponse, response.statusCode != 101 {
            // URLSessionWebSocketTask exposes task.response on some failures, but does not
            // deliver a failed-upgrade body through URLSessionDataDelegate. Never invent one
            // or issue an HTTP "probe" which might execute the command a second time.
            return WebSocketHandshakeError(statusCode: response.statusCode)
        }
        if let error {
            let sanitized = transportError(error)
            if sanitized is CancellationError { return sanitized }
            if let api = sanitized as? APIError, api != .transport(.connection) { return api }
            let nsError = error as NSError
            if nsError.domain != NSURLErrorDomain || nsError.code != URLError.badServerResponse.rawValue {
                return sanitized
            }
        }
        return APIError.transport(.upgradeResponseUnavailable)
    }
}
