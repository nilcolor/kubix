import Foundation
import KubixCore
import Testing

@Test(arguments: TransportPurpose.allCases)
func transportPolicyOverridesEveryRequestDefault(_ purpose: TransportPurpose) throws {
    let request = APIRequest(resource: "pods", query: [URLQueryItem(name: "timeoutSeconds", value: "999")])
    let base = try #require(URL(string: "https://synthetic.invalid"))
    let outgoing = try request.urlRequest(baseURL: base, purpose: purpose)
    let policy = TransportPolicy.policy(for: purpose)
    #expect(outgoing.timeoutInterval == policy.idleTimeout)
    switch purpose {
    case .request:
        #expect(policy.idleTimeout == 30)
        #expect(policy.totalTimeout == 60)
    case .watch:
        #expect(policy.idleTimeout == 330)
        #expect(policy.totalTimeout == 330)
        #expect(policy.serverLease == 300)
        let items = URLComponents(url: try #require(outgoing.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.filter { $0.name == "timeoutSeconds" }.map(\.value) == ["300"])
    case .logs, .webSocket:
        #expect(policy.idleTimeout == 86_400)
        #expect(policy.totalTimeout == 604_800)
    }
}

@Test func websocketDeadlinesAreSeparateFromSessionLifetimes() {
    #expect(TransportPolicy.upgradeTimeout == 30)
    #expect(TransportPolicy.pingInterval == 15)
    #expect(TransportPolicy.pongTimeout == 15)
    #expect(TransportPolicy.policy(for: .webSocket).totalTimeout > TransportPolicy.upgradeTimeout)
}
