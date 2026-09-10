import Foundation
import KubixCore

public struct WatchService: PodWatching {
    public typealias TransportFactory = @Sendable (ResolvedContext) async throws -> any Transport
    private let transports: TransportFactory
    private let clock: any TransportClock
    private let jitter: @Sendable () -> Double

    public init(
        transports: @escaping TransportFactory, clock: any TransportClock = ContinuousTransportClock(),
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.transports = transports
        self.clock = clock
        self.jitter = jitter
    }

    public func run(
        context: ResolvedContext, namespace: String,
        update: @escaping @MainActor @Sendable (PodWatchUpdate) -> Void
    ) async {
        var run = PodWatchRun(namespace: namespace, clock: clock, jitter: jitter, update: update)
        do {
            guard NamespaceSelection.isValid(namespace) else { throw APIError.invalidRequest }
            try Task.checkCancellation()
            let transport = try await transports(context)
            try Task.checkCancellation()
            try await run.execute(transport)
        } catch {
            guard !Task.isCancelled else { return }
            await run.publish(.failed(podWatchError(error)))
        }
    }
}

private struct PodWatchRun {
    let namespace: String
    let clock: any TransportClock
    let jitter: @Sendable () -> Double
    let update: @MainActor @Sendable (PodWatchUpdate) -> Void
    var state = WatchState()
    var rejection: APIError?

    mutating func execute(_ transport: any Transport) async throws {
        var listing = true
        while true {
            try Task.checkCancellation()
            let decision: WatchDecision
            if listing {
                decision = try await installList(transport)
            } else {
                decision = try await watch(transport)
            }
            try Task.checkCancellation()
            switch decision {
            case .watch: listing = false
            case .relist:
                listing = true
                await publish(.connecting)
            case .retry(let delay, _):
                await publish(.connecting)
                try await clock.wait(until: clock.now + delay)
            case .refreshCredentials:
                await publish(.connecting)
                guard let rejection else { throw APIError.watch(.credentialRefreshLimit) }
                do { try await transport.invalidateCredentials(after: rejection) } catch {
                    try Task.checkCancellation()
                    throw APIError.watch(.credentialRefreshLimit)
                }
            case .failed, .stopped, .applied: throw decisionError(decision)
            }
        }
    }

    private mutating func installList(_ transport: any Transport) async throws -> WatchDecision {
        let transition = state.resumeListing()
        guard transition == .relist else { return transition }
        do {
            let snapshot = try await list(transport)
            try Task.checkCancellation()
            guard let version = snapshot.resourceVersion else { throw APIError.podSnapshot(.missingResourceVersion) }
            let decision = state.installSnapshot(rows: snapshot.rows, columns: snapshot.columns, resourceVersion: version)
            if case .watch = decision { await publish(.connecting) }
            return decision
        } catch {
            try Task.checkCancellation()
            let failure = podWatchError(error)
            rejection = failure
            return state.failedRequest(failure, jitter: jitter())
        }
    }

    private func list(_ transport: any Transport) async throws -> PodSnapshot {
        var snapshot = PodSnapshot()
        repeat {
            try Task.checkCancellation()
            var query = [URLQueryItem(name: "limit", value: "500"), URLQueryItem(name: "includeObject", value: "Metadata")]
            if !snapshot.cursor.isEmpty { query.append(URLQueryItem(name: "continue", value: snapshot.cursor)) }
            let request = APIRequest(resource: "pods", namespace: namespace, query: query, table: true, managesCredentialRefresh: true)
            let data = try await transport.data(for: request)
            try Task.checkCancellation()
            try snapshot.append(data, namespace: namespace)
        } while !snapshot.cursor.isEmpty
        return snapshot
    }

    private mutating func watch(_ transport: any Transport) async throws -> WatchDecision {
        let transition = state.resume()
        guard case .watch(let version) = transition else { return transition }
        let started = clock.now
        let deadline = started + TransportPolicy.policy(for: .watch).totalTimeout
        let query = [
            URLQueryItem(name: "includeObject", value: "Metadata"),
            URLQueryItem(name: "watch", value: "true"),
            URLQueryItem(name: "allowWatchBookmarks", value: "true"),
            URLQueryItem(name: "timeoutSeconds", value: String(TransportPolicy.policy(for: .watch).serverLease!)),
            URLQueryItem(name: "resourceVersion", value: version),
        ]
        let request = APIRequest(resource: "pods", namespace: namespace, query: query, table: true, managesCredentialRefresh: true)
        do {
            let stream = try await withTransportDeadline(until: deadline, clock: clock) {
                let stream = try await transport.stream(for: request, purpose: .watch)
                if Task.isCancelled { stream.cancel(); throw CancellationError() }
                return stream
            }
            defer { stream.cancel() }
            try Task.checkCancellation()
            await publish(.live)
            return try await consume(stream, started: started, deadline: deadline)
        } catch {
            try Task.checkCancellation()
            let failure = podWatchError(error)
            rejection = failure
            return state.failedRequest(failure, jitter: jitter())
        }
    }

    private mutating func consume(_ stream: any HTTPByteStream, started: TimeInterval, deadline: TimeInterval) async throws -> WatchDecision {
        var decoder = WatchEventDecoder()
        while true {
            let data = try await withTransportDeadline(until: deadline, clock: clock, cancel: stream.cancel) {
                try await stream.read()
            }
            try Task.checkCancellation()
            let events = data.map { decoder.append($0) } ?? decoder.finish()
            for result in events {
                let decision: WatchDecision
                switch result {
                case .success(let event):
                    try checkRowBudget(event)
                    decision = state.receive(event, jitter: jitter())
                    if case .error(let status) = event, decision == .refreshCredentials {
                        rejection = stream.credentialRejection(.status(status, httpCode: 401, resource: "pods watch"))
                    }
                case .failure(let error): decision = state.decodingFailed(error)
                }
                guard decision == .applied else { return decision }
                await publish(.live)
                try Task.checkCancellation()
            }
            if data == nil { return state.end(.eof, elapsed: clock.now - started, jitter: jitter()) }
        }
    }

    private func checkRowBudget(_ event: WatchEvent) throws {
        switch event {
        case .added(let table), .modified(let table):
            let newIDs = Set(table.rows.compactMap { $0.object?.metadata?.uid }).filter { state.rowsByUID[$0] == nil }
            guard newIDs.count <= PodSnapshot.maximumRows - state.rowsByUID.count else { throw APIError.podSnapshot(.rowLimit) }
        default: break
        }
    }

    func publish(_ connection: PodConnection) async {
        guard !Task.isCancelled else { return }
        await update(PodWatchUpdate(rows: state.rows, columns: state.columns, connection: connection))
    }

    private func decisionError(_ decision: WatchDecision) -> APIError {
        if case .failed(let failure) = decision {
            if case .api(let error) = failure { return error }
            return .watch(failure)
        }
        return .watch(.invalidTransition)
    }
}

private func podWatchError(_ error: any Error) -> APIError {
    if let error = error as? APIError { return error }
    if error is AuthError || error is AuthenticationError || error is KubeconfigError { return .podAuthentication }
    if error is DecodingError { return .podSnapshot(.malformedTable) }
    return .transport(.invalidResponse)
}
