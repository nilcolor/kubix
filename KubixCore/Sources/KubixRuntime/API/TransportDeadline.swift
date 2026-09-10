import Foundation
import KubixCore

public struct ContinuousTransportClock: TransportClock {
    public init() {}
    public var now: TimeInterval { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    public func wait(until deadline: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, deadline - now)))
    }
}

/// IO seams must unblock on cancellation. Timeout also cancels the resource explicitly, so a
/// ping stuck behind native socket writes cannot keep the structured race alive indefinitely.
func withTransportDeadline<Value: Sendable>(
    until deadline: TimeInterval, clock: any TransportClock, failure: TransportFailure = .timedOut,
    cancel: @escaping @Sendable () -> Void = {},
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let expiry = DeadlineExpiry()
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        guard clock.now < deadline else { cancel(); throw APIError.transport(failure) }
        do {
            return try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await clock.wait(until: deadline)
                    try Task.checkCancellation()
                    expiry.mark()
                    cancel()
                    throw APIError.transport(failure)
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw CancellationError() }
                if expiry.hasExpired || clock.now >= deadline { cancel(); throw APIError.transport(failure) }
                return value
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if expiry.hasExpired { throw APIError.transport(failure) }
            throw error
        }
    } onCancel: { cancel() }
}

private final class DeadlineExpiry: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    var hasExpired: Bool { lock.withLock { expired } }
    func mark() { lock.withLock { expired = true } }
}

/// A single callback result with cancellation that does not depend on Foundation calling back.
final class TransportPromise<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?

    func finish(_ result: Result<Value, any Error>) {
        let pending = lock.withLock {
            guard self.result == nil else { return Optional<CheckedContinuation<Value, any Error>>.none }
            self.result = result
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(with: result)
    }

    func value(cancel: @escaping @Sendable () -> Void) async throws -> Value {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { pending in
                let ready: Result<Value, any Error>? = lock.withLock {
                    if let result { return result }
                    continuation = pending
                    return nil
                }
                if let ready { pending.resume(with: ready) }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
            cancel()
        }
    }
}

func transportError(_ error: any Error) -> any Error {
    if error is CredentialAcquisitionFailure { return error }
    if error is CancellationError || error is APIError || error is AuthenticationError || error is AuthError { return error }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        switch URLError.Code(rawValue: nsError.code) {
        case .cancelled: return CancellationError()
        case .timedOut: return APIError.transport(.timedOut)
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return APIError.tls(.trustEvaluationFailed)
        default: break
        }
    }
    // Never retain localizedDescription/userInfo: both may contain the authenticated request.
    return APIError.transport(.connection)
}
