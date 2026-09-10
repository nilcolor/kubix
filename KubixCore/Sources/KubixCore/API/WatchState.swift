import Foundation

public enum WatchFailure: Error, Equatable, Sendable {
    case decoding(WatchDecodingError), api(APIError)
    case retryLimit, credentialRefreshLimit, invalidTransition
}

public enum WatchDecision: Equatable, Sendable {
    case applied
    case watch(resourceVersion: String)
    case relist
    case refreshCredentials
    case retry(delay: TimeInterval, resourceVersion: String)
    case failed(WatchFailure)
    case stopped
}

public enum WatchEnd: Sendable {
    case eof, disconnected, clientDeadline, cancelled
}

/// A single ordered watch owner supplies monotonic elapsed time and a random sample in 0...1.
/// This performs no IO, sleeping, credential acquisition, pagination or automatic event replay.
public struct WatchState: Sendable {
    public enum Phase: Equatable, Sendable {
        case ready, watching, listing, backingOff, refreshingCredentials, relisting, failed(WatchFailure), stopped
    }

    public private(set) var phase: Phase = .ready
    public private(set) var rowsByUID: [String: PodRow]
    public private(set) var orderedUIDs: [String]
    public private(set) var columns: [KubernetesTable.ColumnDefinition]?
    public private(set) var resourceVersion: String
    public private(set) var retryAttempts = 0
    public private(set) var credentialRefreshes = 0
    public private(set) var relistAttempts = 0
    public var rows: [PodRow] { orderedUIDs.compactMap { rowsByUID[$0] } }
    public static let maximumRetries = 6
    public static let maximumCredentialRefreshes = 1

    /// Initial list shares the same failure budgets as all subsequent watches and relists.
    public init() {
        rowsByUID = [:]
        orderedUIDs = []
        columns = nil
        resourceVersion = ""
        phase = .relisting
    }

    public mutating func resumeListing() -> WatchDecision {
        if let terminal { return terminal }
        guard [.relisting, .backingOff, .refreshingCredentials].contains(phase) else { return fail(.invalidTransition) }
        phase = .listing
        return .relist
    }

    public init(rows: [PodRow], columns: [KubernetesTable.ColumnDefinition]?, resourceVersion: String) throws {
        try Self.validateSnapshot(rows, columns: columns, resourceVersion: resourceVersion)
        rowsByUID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        orderedUIDs = rows.map(\.id)
        self.columns = columns
        self.resourceVersion = resourceVersion
    }

    /// Call only after pending backoff/credential refresh has completed. Opening is not recovery.
    public mutating func resume() -> WatchDecision {
        if let terminal { return terminal }
        guard [.ready, .backingOff, .refreshingCredentials].contains(phase) else { return fail(.invalidTransition) }
        phase = .watching
        return .watch(resourceVersion: resourceVersion)
    }

    public mutating func receive(_ event: WatchEvent, jitter: Double = 0.5) -> WatchDecision {
        if let terminal { return terminal }
        guard phase == .watching else { return fail(.invalidTransition) }
        do { try event.validate() } catch { return decodingFailed(.invalidPayload) }
        switch event {
        case .added(let table), .modified(let table): return apply(table, deleting: false)
        case .deleted(let table): return apply(table, deleting: true)
        case .bookmark(let bookmark): return apply(bookmark)
        case .error(let status):
            return failedRequest(.watchStatus(status), jitter: jitter)
        }
    }

    /// HTTP status is authoritative over a conflicting Status body. In-stream reason-only Status
    /// is mapped by receive(), where no HTTP response code exists.
    public mutating func failedRequest(_ error: APIError, jitter: Double = 0.5) -> WatchDecision {
        if let terminal { return terminal }
        guard phase == .watching || phase == .listing || phase == .refreshingCredentials else { return fail(.invalidTransition) }
        if error.httpCode == 410 { return expire() }
        if error.httpCode == 401 {
            guard !error.credentialRefreshExhausted,
                  credentialRefreshes < Self.maximumCredentialRefreshes else { return fail(.credentialRefreshLimit) }
            credentialRefreshes += 1
            phase = .refreshingCredentials
            return .refreshCredentials
        }
        if error.httpCode == 429 || error.httpCode.map({ (500...599).contains($0) }) == true {
            return retry(jitter: jitter, after: error.retryAfterDelay)
        }
        if case .transport(let failure) = error, [.connection, .closed, .timedOut].contains(failure) {
            return retry(jitter: jitter)
        }
        return fail(.api(error))
    }

    public mutating func end(_ end: WatchEnd, elapsed: TimeInterval, jitter: Double = 0.5) -> WatchDecision {
        if case .cancelled = end { return cancel() }
        if let terminal { return terminal }
        guard phase == .watching, elapsed.isFinite, elapsed >= 0 else { return fail(.invalidTransition) }
        let policy = TransportPolicy.policy(for: .watch)
        if case .eof = end, elapsed >= TimeInterval(policy.serverLease!), elapsed < policy.totalTimeout {
            // Only a completed healthy lease resets budgets, never opening or a single data/bookmark.
            retryAttempts = 0
            credentialRefreshes = 0
            relistAttempts = 0
            phase = .ready
            return .watch(resourceVersion: resourceVersion)
        }
        return retry(jitter: jitter)
    }

    /// A complete relist snapshot can be installed without resetting failed-session budgets.
    public mutating func installSnapshot(
        rows: [PodRow], columns: [KubernetesTable.ColumnDefinition]?, resourceVersion: String
    ) -> WatchDecision {
        if let terminal { return terminal }
        guard phase == .relisting || phase == .listing else { return fail(.invalidTransition) }
        do {
            try Self.validateSnapshot(rows, columns: columns, resourceVersion: resourceVersion)
        } catch { return decodingFailed(.invalidPayload) }
        rowsByUID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        orderedUIDs = rows.map(\.id)
        self.columns = columns
        self.resourceVersion = resourceVersion
        phase = .ready
        return .watch(resourceVersion: resourceVersion)
    }

    public mutating func decodingFailed(_ error: WatchDecodingError) -> WatchDecision {
        if let terminal { return terminal }
        return fail(.decoding(error))
    }

    public mutating func cancel() -> WatchDecision {
        phase = .stopped
        return .stopped
    }

    private var terminal: WatchDecision? {
        switch phase {
        case .stopped: .stopped
        case .failed(let error): .failed(error)
        default: nil
        }
    }

    private mutating func apply(_ table: KubernetesTable, deleting: Bool) -> WatchDecision {
        do {
            let data = try WatchEvent.dataRows(table)
            let schema = table.columns(reusing: columns)
            var updated = rowsByUID
            var order = orderedUIDs
            for row in data.rows {
                if let schema, schema.count != row.cells.count { throw WatchDecodingError.invalidPayload }
                if deleting {
                    updated.removeValue(forKey: row.id)
                    order.removeAll { $0 == row.id }
                } else {
                    if updated[row.id] == nil { order.append(row.id) }
                    updated[row.id] = row
                }
            }
            try Self.validateSnapshot(order.compactMap { updated[$0] }, columns: schema, resourceVersion: data.resourceVersion)
            rowsByUID = updated
            orderedUIDs = order
            columns = schema
            resourceVersion = data.resourceVersion
            return .applied
        } catch { return decodingFailed(.invalidPayload) }
    }

    private mutating func apply(_ bookmark: WatchBookmark) -> WatchDecision {
        let schema = bookmark.columnDefinitions ?? columns
        do {
            try Self.validateSnapshot(rows, columns: schema, resourceVersion: bookmark.resourceVersion)
        } catch { return decodingFailed(.invalidPayload) }
        columns = schema
        resourceVersion = bookmark.resourceVersion
        return .applied
    }

    private mutating func expire() -> WatchDecision {
        rowsByUID.removeAll()
        orderedUIDs.removeAll()
        columns = nil
        resourceVersion = ""
        guard relistAttempts < Self.maximumRetries else { return fail(.retryLimit) }
        relistAttempts += 1
        phase = .relisting
        return .relist
    }

    private mutating func retry(jitter: Double, after delay: TimeInterval? = nil) -> WatchDecision {
        guard jitter.isFinite, (0...1).contains(jitter),
              delay.map({ $0.isFinite && $0 >= 0 }) ?? true else { return fail(.invalidTransition) }
        guard retryAttempts < Self.maximumRetries else { return fail(.retryLimit) }
        let ceiling = min(30, pow(2, Double(retryAttempts)))
        retryAttempts += 1
        phase = .backingOff
        return .retry(delay: max(ceiling * (0.5 + jitter * 0.5), delay ?? 0), resourceVersion: resourceVersion)
    }

    private mutating func fail(_ failure: WatchFailure) -> WatchDecision {
        phase = .failed(failure)
        return .failed(failure)
    }

    private static func validateSnapshot(
        _ rows: [PodRow], columns: [KubernetesTable.ColumnDefinition]?, resourceVersion: String
    ) throws {
        guard !resourceVersion.isEmpty, Set(rows.map(\.id)).count == rows.count,
              columns.map({ schema in rows.allSatisfy { $0.cells.count == schema.count } }) ?? true else {
            throw WatchDecodingError.invalidPayload
        }
    }

}
