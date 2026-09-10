import Foundation
import KubixCore
import Testing

@Test func requestPreservesBasePathAndExplicitTableAccept() throws {
    let base = try #require(URL(string: "https://synthetic.invalid/gateway/a%20b/"))
    let table = try APIRequest(
        resource: "pods", namespace: "team", query: [URLQueryItem(name: "limit", value: "500")], table: true
    ).urlRequest(baseURL: base)
    #expect(table.url?.absoluteString == "https://synthetic.invalid/gateway/a%20b/api/v1/namespaces/team/pods?limit=500")
    #expect(table.value(forHTTPHeaderField: "Accept") == APIRequest.tableAccept)
    for subresource in [nil, "log"] {
        let detail = try APIRequest(resource: "pods", namespace: "team", name: "pod", subresource: subresource).urlRequest(baseURL: base)
        #expect(detail.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(detail.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

@Test func clusterScopedAndGroupedResourcePaths() throws {
    let base = try #require(URL(string: "https://synthetic.invalid"))
    #expect(try APIRequest(resource: "namespaces").urlRequest(baseURL: base).url?.path == "/api/v1/namespaces")
    #expect(try APIRequest(resource: "deployments", apiPath: ["apis", "apps", "v1"]).urlRequest(baseURL: base).url?.path == "/apis/apps/v1/deployments")
}

@Test func queryAndSegmentsEncodeExactlyOnceWithRepeatedCommands() throws {
    let request = APIRequest(resource: "pods", namespace: "a/b", name: "é ?#%", subresource: "exec", query: [
        URLQueryItem(name: "command", value: "sh"),
        URLQueryItem(name: "command", value: "-c"),
        URLQueryItem(name: "command", value: "echo a+b&x=/"),
        URLQueryItem(name: "odd&key", value: ""),
    ])
    let base = try #require(URL(string: "https://synthetic.invalid/base"))
    let url = try #require(try request.urlRequest(baseURL: base, purpose: .webSocket).url)
    #expect(url.absoluteString == "wss://synthetic.invalid/base/api/v1/namespaces/a%2Fb/pods/%C3%A9%20%3F%23%25/exec?command=sh&command=-c&command=echo%20a%2Bb%26x%3D%2F&odd%26key=")
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "command" }.map(\.value) == ["sh", "-c", "echo a+b&x=/"])
    #expect(!request.description.contains("echo"))
}

@Test(arguments: [
    "https://user:password@synthetic.invalid", "file:///path", "https://synthetic.invalid?token=secret",
    "https://synthetic.invalid#fragment",
])
func unsafeBaseURLsAreRejected(_ value: String) throws {
    let base = try #require(URL(string: value))
    #expect(throws: APIError.invalidRequest) { try APIRequest(resource: "pods").urlRequest(baseURL: base) }
}

@Test(arguments: ["", ".", ".."])
func invalidSegmentsAreRejected(_ segment: String) throws {
    let base = try #require(URL(string: "https://synthetic.invalid"))
    #expect(throws: APIError.invalidRequest) { try APIRequest(resource: "pods", name: segment).urlRequest(baseURL: base) }
}

@Test(arguments: [(403, "Forbidden"), (404, "NotFound"), (410, "Gone")])
func statusFixturesDecodeWithResourceContext(code: Int, reason: String) throws {
    let url = try #require(Bundle.module.url(forResource: "status-\(code)", withExtension: "json", subdirectory: "Fixtures"))
    let error = APIError.response(code: code, body: try Data(contentsOf: url), resource: "pods/exec")
    guard case .status(let status, let httpCode, let resource) = error else { Issue.record("Expected Status"); return }
    #expect(status.code == code)
    #expect(status.reason == reason)
    #expect(status.message?.isEmpty == false)
    #expect(httpCode == code)
    #expect(resource == "pods/exec")
    #expect(error.description.contains("pods/exec"))
    #expect(error.description.contains(reason))
}

@Test(arguments: [
    "<html>gateway secret error</html>", "{}", #"{"apiVersion":"v2","kind":"Status","code":403}"#,
    #"{"apiVersion":"v1","kind":"Other","code":403}"#, #"{"apiVersion":"v1","kind":"Status","code":"403"}"#,
])
func nonStatusBodiesAreNotRetained(_ body: String) {
    let error = APIError.response(code: 403, body: Data(body.utf8), resource: "pods")
    #expect(error == .http(code: 403, resource: "pods"))
    #expect(!error.description.contains("secret"))
}

@Test func statusCannotEchoBearerMaterialAndHTTPCodeIsAuthoritative() {
    let body = Data(#"{"apiVersion":"v1","kind":"Status","reason":"secret-token","message":"Bearer secret-token","code":401}"#.utf8)
    let error = APIError.response(code: 403, body: body, resource: "pods", redacting: "secret-token")
    #expect(error.httpCode == 403)
    #expect(!String(reflecting: error).contains("secret-token"))
    #expect(!error.description.contains("secret-token"))
    #expect(APIError.response(code: 500, body: Data(repeating: 65, count: 65_537), resource: "pods") == .http(code: 500, resource: "pods"))
    #expect(APIError.tls(.trustEvaluationFailed) != .transport(.connection))
}
