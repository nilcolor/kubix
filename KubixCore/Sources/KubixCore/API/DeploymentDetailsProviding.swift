import Foundation

/// Every call fetches fresh details and checks the captured Table identity before returning.
public protocol DeploymentDetailsProviding: Sendable {
    func details(context: ResolvedContext, namespace: String, name: String, uid: String) async throws -> DeploymentDetails
}
