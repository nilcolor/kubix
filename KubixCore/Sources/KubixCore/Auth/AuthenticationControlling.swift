import Foundation

/// Only deliberately sanitized application diagnostics conform. Never use a generic
/// localizedDescription: an underlying process/network error can contain credentials.
public protocol AuthenticationDiagnosticProviding: Error {
    var authenticationDiagnostic: String { get }
}

/// AppActions can subscribe and present Sign in/Retry/Cancel without importing runtime IO.
public protocol AuthenticationControlling: Sendable {
    func presentation(for context: ResolvedContext) async -> AuthPluginPresentation
    func update(settings: AuthSettings) async throws
    func acquire(for context: ResolvedContext) async throws -> AcquiredCredential
    func signIn(for context: ResolvedContext, useDeviceCode: Bool) async throws -> AcquiredCredential
    func sessions() async -> AsyncStream<AuthSession>
    /// Global cancellation of the selected shared operation, unlike cancelling an individual caller.
    func cancel(operationID: UUID) async
    /// Always an explicit user action; terminal operations are never restarted automatically.
    func retry(operationID: UUID) async throws -> AcquiredCredential
}

public extension AuthenticationControlling {
    func presentation(for context: ResolvedContext) async -> AuthPluginPresentation { AuthPluginPresentation() }
}
