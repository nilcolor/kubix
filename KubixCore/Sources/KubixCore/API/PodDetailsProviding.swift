import Foundation

/// Every call fetches fresh details and checks the original Table identity before returning.
public protocol PodDetailsProviding: Sendable {
    func details(context: ResolvedContext, namespace: String, name: String, uid: String) async throws -> PodDetails
}
