import Foundation
import KubixCore
import KubixRuntime
import Testing
import Yams

struct UnsupportedAuthConfigurationTests {
    @Test(arguments: [
        #""auth-provider":{"name":"oidc","config":{"id-token":"SYNTHETIC-SECRET"}}"#,
        #""username":"SYNTHETIC-SECRET""#, #""password":"SYNTHETIC-SECRET""#,
        #""as":"SYNTHETIC-SECRET""#, #""as-uid":"SYNTHETIC-SECRET""#,
        #""as-groups":["SYNTHETIC-SECRET"]"#, #""as-user-extra":{"extra":["SYNTHETIC-SECRET"]}"#,
    ])
    func unsupportedSelectedUserFailsBeforeCredentialsAndIOAndSurvivesRoundTrips(_ field: String) async throws {
        let user = try JSONDecoder().decode(KubeconfigUser.self, from: Data("""
        {"token":"synthetic-supported-token","exec":{"command":"plugin","apiVersion":"client.authentication.k8s.io/v1","interactiveMode":"Never"},\(field)}
        """.utf8))
        #expect(user.unsupportedAuthenticationFields.count == 1)
        let json = try JSONEncoder().encode(user)
        #expect(!String(decoding: json, as: UTF8.self).contains("SYNTHETIC-SECRET"))
        let yaml = try YAMLEncoder().encode(user)
        let variants = [user, try JSONDecoder().decode(KubeconfigUser.self, from: json), try YAMLDecoder().decode(KubeconfigUser.self, from: yaml)]
        let process = FakeProcess()
        let materials = MaterialFiles()
        let provider = CredentialProvider(resolver: testResolver(), runner: CredentialRunner(process: process), materials: materials)
        let factory = RecordingSessionFactory()
        for variant in variants {
            #expect(variant.unsupportedAuthenticationFields == user.unsupportedAuthenticationFields)
            let configuration = Kubeconfig(
                currentContext: "unsupported",
                clusters: [.init(name: "cluster", cluster: .init(server: "https://synthetic.invalid"))],
                contexts: [
                    .init(name: "unsupported", context: .init(cluster: "cluster", user: "user")),
                    .init(name: "anonymous", context: .init(cluster: "cluster")),
                ], users: [.init(name: "user", user: variant)]
            )
            #expect(throws: KubeconfigError.unsupportedAuthentication) { try configuration.resolve() }
            #expect(try AuthMethod.resolve(from: configuration.resolve(context: "anonymous")) == .anonymous)
            await #expect(throws: KubeconfigError.unsupportedAuthentication) {
                try await URLSessionTransport.activate(
                    configuration: configuration, credentials: provider, materials: materials, factory: factory, warning: { _ in }
                )
            }
        }
        #expect(await process.requests().isEmpty)
        #expect(await materials.reads.isEmpty)
        #expect(factory.policies.isEmpty)
        #expect(!KubeconfigError.unsupportedAuthentication.description.contains("SYNTHETIC-SECRET"))
    }

    @Test func authProviderAndBasicAuthCannotFallThroughToAnonymousWithoutToken() throws {
        for json in [#"{"auth-provider":{}}"#, #"{"username":"name","password":"synthetic"}"#] {
            let user = try JSONDecoder().decode(KubeconfigUser.self, from: Data(json.utf8))
            #expect(throws: KubeconfigError.unsupportedAuthentication) { try runtimeContext(user: user) }
        }
        #expect(try AuthMethod.resolve(from: runtimeContext(user: .init())) == .anonymous)
        #expect(try AuthMethod.resolve(from: runtimeContext(user: .init(token: "synthetic"))) == .token("synthetic"))
    }
}
