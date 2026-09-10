import Foundation
import KubixCore
import Testing

private final class AuthClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_000)

    func now() -> Date { lock.withLock { instant } }
    func set(_ seconds: TimeInterval) { lock.withLock { instant = Date(timeIntervalSince1970: seconds) } }
}

private func cachedCredential(expiringAt seconds: TimeInterval? = nil) throws -> Credential {
    try Credential(token: "synthetic-token", expirationTimestamp: seconds.map(Date.init(timeIntervalSince1970:)))
}

@Test func credentialCacheMissingExpiryPersistsUntilMatchingInvalidationOrClear() throws {
    let clock = AuthClock()
    var cache = CredentialCache(now: clock.now)
    let identity = try CredentialIdentity(from: authContext())
    #expect(cache.lookup(for: identity) == .missing)
    let entry = try cache.store(cachedCredential(), for: identity)
    #expect(entry.refreshAfter == nil)
    clock.set(1_000_000_000)
    #expect(cache.lookup(for: identity) == .fresh(entry))
    #expect(cache.invalidate(identity, generation: entry.generation) == true)
    #expect(cache.lookup(for: identity) == .missing)
    #expect(cache.invalidate(identity, generation: entry.generation) == false)
    let replacement = try cache.store(cachedCredential(), for: identity)
    cache.removeAll()
    #expect(cache.lookup(for: identity) == .missing)
    let afterClear = try cache.store(cachedCredential(), for: identity)
    #expect(afterClear.generation != replacement.generation)
    #expect(cache.invalidate(identity, generation: replacement.generation) == false)
    #expect(cache.lookup(for: identity) == .fresh(afterClear))
}

@Test func credentialCacheSeparatesRefreshWindowAndActualExpiry() throws {
    let clock = AuthClock()
    var cache = CredentialCache(now: clock.now)
    let identity = try CredentialIdentity(from: authContext())
    let entry = try cache.store(cachedCredential(expiringAt: 1_300), for: identity)
    #expect(entry.refreshAfter == Date(timeIntervalSince1970: 1_240))
    clock.set(1_239.999)
    #expect(cache.lookup(for: identity) == .fresh(entry))
    clock.set(1_240)
    #expect(cache.lookup(for: identity) == .refreshDue(entry))
    clock.set(1_299.999)
    #expect(cache.lookup(for: identity) == .refreshDue(entry))
    clock.set(1_300)
    #expect(cache.lookup(for: identity) == .expired(entry))
    clock.set(1_301)
    #expect(cache.lookup(for: identity) == .expired(entry))
}

@Test(arguments: [-1.0, 0, 10, 60, 61, 10_000, .infinity, -.infinity, .nan])
func credentialCacheBoundsConfigurableSkew(window: TimeInterval) throws {
    let clock = AuthClock()
    var cache = CredentialCache(now: clock.now, earlyRefreshWindow: window)
    let identity = try CredentialIdentity(from: authContext())
    let entry = try cache.store(cachedCredential(expiringAt: 2_000), for: identity)
    let expected = window > 0 ? min(window, 60) : 0
    #expect(entry.refreshAfter == Date(timeIntervalSince1970: 2_000 - expected))
    clock.set(2_000 - expected)
    #expect(cache.lookup(for: identity) == (expected == 0 ? .expired(entry) : .refreshDue(entry)))
}

@Test(arguments: [0.001, 1, 30, 60, 119, 120, 121])
func credentialCacheNewShortLivedCredentialIsFresh(lifetime: TimeInterval) throws {
    let clock = AuthClock()
    var cache = CredentialCache(now: clock.now)
    let identity = try CredentialIdentity(from: authContext())
    let credential = try cachedCredential(expiringAt: 1_000 + lifetime)
    let entry = try cache.store(credential, for: identity)
    let refresh = try #require(entry.refreshAfter)
    #expect(refresh > clock.now())
    #expect(refresh == Date(timeIntervalSince1970: 1_000 + lifetime - min(60, lifetime / 2)))
    #expect(cache.lookup(for: identity) == .fresh(entry))
    clock.set(refresh.timeIntervalSince1970)
    #expect(cache.lookup(for: identity) == .refreshDue(entry))
    // Even a plugin returning the same fixed expiration does not cause immediate reacquisition.
    let refreshed = try cache.store(credential, for: identity)
    #expect(cache.lookup(for: identity) == .fresh(refreshed))
    #expect(refreshed.generation != entry.generation)
    #expect(try #require(refreshed.refreshAfter) > refresh)
}

@Test func credentialCacheSubprecisionSkewNeverRefreshesImmediately() throws {
    let clock = AuthClock()
    var cache = CredentialCache(now: clock.now)
    let identity = try CredentialIdentity(from: authContext())
    let now = clock.now()
    let expiration = Date(timeIntervalSinceReferenceDate: now.timeIntervalSinceReferenceDate.nextUp)
    let entry = try cache.store(Credential(token: "synthetic-token", expirationTimestamp: expiration), for: identity)
    #expect(cache.lookup(for: identity) == .fresh(entry))
    #expect(entry.refreshAfter == expiration)
}

@Test(arguments: [999.0, 1_000])
func credentialCacheRejectsExpiredOnArrivalWithoutReplacingEntry(expiration: TimeInterval) throws {
    let clock = AuthClock()
    var cache = CredentialCache(now: clock.now)
    let identity = try CredentialIdentity(from: authContext())
    let entry = try cache.store(cachedCredential(), for: identity)
    #expect(throws: AuthError.expiredCredential) { try cache.store(cachedCredential(expiringAt: expiration), for: identity) }
    #expect(cache.lookup(for: identity) == .fresh(entry))
}

@Test func credentialCacheStaleGenerationsCannotInvalidateReplacementsOrOtherIdentities() throws {
    let clock = AuthClock()
    var cache = CredentialCache(now: clock.now)
    let identity = try CredentialIdentity(from: authContext())
    let other = try CredentialIdentity(from: authContext(user: KubeconfigUser(token: "synthetic-other-token")))
    let old = try cache.store(cachedCredential(), for: identity)
    #expect(cache.invalidate(identity, generation: old.generation) == true)
    #expect(cache.invalidate(identity, generation: old.generation) == false)
    let newer = try cache.store(cachedCredential(), for: identity)
    let unrelated = try cache.store(cachedCredential(), for: other)
    #expect(old.generation != newer.generation)
    #expect(newer.generation != unrelated.generation)
    #expect(cache.invalidate(identity, generation: old.generation) == false)
    #expect(cache.invalidate(other, generation: newer.generation) == false)
    #expect(cache.lookup(for: identity) == .fresh(newer))
    #expect(cache.lookup(for: other) == .fresh(unrelated))
    let newest = try cache.store(cachedCredential(), for: identity)
    #expect(cache.invalidate(identity, generation: newer.generation) == false)
    #expect(cache.lookup(for: identity) == .fresh(newest))
    #expect(cache.invalidate(identity, generation: newest.generation) == true)
    #expect(cache.lookup(for: other) == .fresh(unrelated))
}

@Test func credentialCacheAppliesSameLifecycleToCertificateResults() throws {
    let clock = AuthClock()
    var cache = CredentialCache(now: clock.now)
    let identity = try CredentialIdentity(from: authContext())
    let credential = try Credential(
        clientCertificateData: "synthetic-cert", clientKeyData: "synthetic-key",
        expirationTimestamp: Date(timeIntervalSince1970: 1_100)
    )
    let entry = try cache.store(credential, for: identity)
    #expect(cache.lookup(for: identity) == .fresh(entry))
    clock.set(1_050)
    #expect(cache.lookup(for: identity) == .refreshDue(entry))
    clock.set(1_100)
    #expect(cache.lookup(for: identity) == .expired(entry))
    #expect(cache.invalidate(identity, generation: entry.generation) == true)
}

@Test func credentialCacheDescriptionsAndReflectionNeverExposeMaterial() throws {
    let clock = AuthClock()
    var cache = CredentialCache(now: clock.now)
    let identity = try CredentialIdentity(from: authContext())
    let entry = try cache.store(cachedCredential(), for: identity)
    for value: Any in [cache, entry, cache.lookup(for: identity)] {
        var dumped = ""
        dump(value, to: &dumped)
        #expect(!"\(value) \(String(reflecting: value)) \(dumped)".contains("synthetic"))
    }
}
