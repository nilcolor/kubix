import Foundation

/// Pure in-memory lifecycle policy. Its runtime owner serializes access and coalesces acquisitions.
public struct CredentialCache: Sendable, CustomStringConvertible, CustomReflectable {
    public struct Generation: Hashable, Sendable {
        fileprivate let value: UInt64
    }

    public struct Entry: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
        public let credential: Credential
        public let generation: Generation
        public let refreshAfter: Date?
        public var description: String { "CredentialCache.Entry (contents redacted)" }
        public var customMirror: Mirror { Mirror(self, children: ["contents": "redacted"]) }
    }

    /// Refresh-due credentials are still usable; expired credentials are not.
    public enum Lookup: Equatable, Sendable {
        case missing
        case fresh(Entry)
        case refreshDue(Entry)
        case expired(Entry)
    }

    private let now: @Sendable () -> Date
    private let earlyRefreshWindow: TimeInterval
    private var entries: [CredentialIdentity: Entry] = [:]
    private var lastGeneration: UInt64 = 0

    public var description: String { "CredentialCache (contents redacted)" }
    public var customMirror: Mirror { Mirror(self, children: ["contents": "redacted"]) }

    public init(now: @escaping @Sendable () -> Date, earlyRefreshWindow: TimeInterval = 60) {
        self.now = now
        self.earlyRefreshWindow = earlyRefreshWindow > 0 ? min(earlyRefreshWindow, 60) : 0
    }

    /// Omitted expiry never triggers time-based refresh. Expired-on-arrival results cannot
    /// replace an existing generation. Generations are never reset by invalidation or clearing.
    @discardableResult
    public mutating func store(_ credential: Credential, for identity: CredentialIdentity) throws -> Entry {
        let acquiredAt = now()
        var refreshAfter: Date?
        if let expiration = credential.expirationTimestamp {
            guard expiration > acquiredAt else { throw AuthError.expiredCredential }
            // Reserve at least half the remaining lifetime for use, including tokens shorter
            // than 60s. Reacquisition must never return a credential already in its refresh window.
            let skew = min(earlyRefreshWindow, expiration.timeIntervalSince(acquiredAt) / 2)
            let candidate = expiration.addingTimeInterval(-skew)
            refreshAfter = candidate > acquiredAt ? candidate : expiration
        }
        lastGeneration += 1
        let entry = Entry(credential: credential, generation: Generation(value: lastGeneration), refreshAfter: refreshAfter)
        entries[identity] = entry
        return entry
    }

    public func lookup(for identity: CredentialIdentity) -> Lookup {
        guard let entry = entries[identity] else { return .missing }
        let instant = now()
        if let expiration = entry.credential.expirationTimestamp, instant >= expiration { return .expired(entry) }
        if let refreshAfter = entry.refreshAfter, instant >= refreshAfter { return .refreshDue(entry) }
        return .fresh(entry)
    }

    /// A delayed 401 may remove only the generation that made that request, never a replacement.
    @discardableResult
    public mutating func invalidate(_ identity: CredentialIdentity, generation: Generation) -> Bool {
        guard entries[identity]?.generation == generation else { return false }
        entries.removeValue(forKey: identity)
        return true
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
