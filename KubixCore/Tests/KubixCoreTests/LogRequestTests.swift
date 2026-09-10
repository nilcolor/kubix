import Foundation
import KubixCore
import Testing

@Suite struct LogRequestTests {
    @Test func allOptionsUsePlainJSONAndEncodeExactlyOnce() throws {
        let log = try LogRequest(
            namespace: "team", pod: "pod %", container: "a+b&é", follow: true,
            tailLines: 0, timestamps: false, sinceSeconds: 75, previous: true
        )
        let request = try log.request.urlRequest(baseURL: #require(URL(string: "https://synthetic.invalid/prefix")), purpose: log.purpose)
        #expect(request.url?.absoluteString == "https://synthetic.invalid/prefix/api/v1/namespaces/team/pods/pod%20%25/log?follow=true&container=a%2Bb%26%C3%A9&timestamps=false&previous=true&tailLines=0&sinceSeconds=75")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == 86_400)
        #expect(TransportPolicy.policy(for: log.purpose).totalTimeout == 604_800)
    }

    @Test func finiteRequestsUseFinitePolicyAndOptionalOptionsAreOmitted() throws {
        let log = try LogRequest(namespace: "team", pod: "pod", container: "web", follow: false, tailLines: nil)
        #expect(log.purpose == .request)
        #expect(TransportPolicy.policy(for: log.purpose).idleTimeout == 30)
        #expect(TransportPolicy.policy(for: log.purpose).totalTimeout == 60)
        #expect(log.request.query.map(\.name) == ["follow", "container", "timestamps", "previous"])
        #expect(!log.request.query.contains { $0.name == "timeoutSeconds" || $0.name == "limit" || $0.name == "includeObject" })
    }

    @Test(arguments: [-1, -100])
    func rejectsNegativeTail(_ value: Int) {
        #expect(throws: APIError.invalidRequest) { try LogRequest(namespace: "team", pod: "pod", container: "web", tailLines: value) }
    }

    @Test(arguments: [0, -1])
    func rejectsNonpositiveSince(_ value: Int) {
        #expect(throws: APIError.invalidRequest) { try LogRequest(namespace: "team", pod: "pod", container: "web", sinceSeconds: value) }
    }

    @Test(arguments: ["", ".", "..", "a/b", "a\u{0}"])
    func rejectsInvalidTargets(_ value: String) {
        #expect(throws: APIError.invalidRequest) { try LogRequest(namespace: "team", pod: value, container: "web") }
        #expect(throws: APIError.invalidRequest) { try LogRequest(namespace: "team", pod: "pod", container: value) }
    }
}
