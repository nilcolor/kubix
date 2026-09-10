import Foundation
import KubixCore

/// Applies the same policy even when session IO is injected. The resource deadline starts at
/// request dispatch (before headers), and does not reset on each read or each server byte.
actor PolicyByteStream: HTTPByteStream {
    private let underlying: any HTTPByteStream
    private let clock: any TransportClock
    private let totalDeadline: TimeInterval
    private let idleTimeout: TimeInterval
    private var lastActivity: TimeInterval
    private var reading = false
    private var ended = false

    init(underlying: any HTTPByteStream, policy: TransportPolicy, started: TimeInterval, clock: any TransportClock) {
        self.underlying = underlying
        self.clock = clock
        totalDeadline = started + policy.totalTimeout
        idleTimeout = policy.idleTimeout
        lastActivity = clock.now
    }

    func read() async throws -> Data? {
        guard !reading else { throw APIError.transport(.streamReadInProgress) }
        guard !ended else { return nil }
        reading = true
        defer { reading = false }
        do {
            let bytes = try await withTransportDeadline(
                until: min(totalDeadline, lastActivity + idleTimeout), clock: clock,
                cancel: underlying.cancel
            ) { try await self.underlying.read() }
            lastActivity = clock.now
            if bytes == nil { ended = true; underlying.cancel() }
            return bytes
        } catch {
            ended = true
            underlying.cancel()
            throw transportError(error)
        }
    }

    nonisolated func cancel() { underlying.cancel() }
    deinit { underlying.cancel() }
}
