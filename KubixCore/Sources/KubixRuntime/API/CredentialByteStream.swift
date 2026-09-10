import Foundation
import KubixCore

/// Retains only the generation receipt, not the token, for an in-stream Unauthorized Status.
struct CredentialByteStream: HTTPByteStream {
    let underlying: any HTTPByteStream
    let identity: CredentialIdentity
    let generation: CredentialCache.Generation?

    func read() async throws -> Data? { try await underlying.read() }
    func cancel() { underlying.cancel() }
    func credentialRejection(_ error: APIError) -> APIError {
        guard error.httpCode == 401, let generation else { return error }
        return .credentialRejected(error, identity: identity, generation: generation)
    }
}
