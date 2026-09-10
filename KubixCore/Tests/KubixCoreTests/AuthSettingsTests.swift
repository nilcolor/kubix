import Foundation
import KubixCore
import Testing

@Test func authSettingsDefaultsAndNonsecretRoundTrip() throws {
    #expect(AuthSettings().timeout == 600)
    let settings = AuthSettings(
        searchDirectories: ["/synthetic/mise/shims"],
        executableOverrides: ["aws": "/synthetic/aws"],
        awsProfiles: ["user": AWSProfileBinding(profile: "dev", session: "company")], timeout: 900
    )
    try settings.validate()
    let bytes = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(AuthSettings.self, from: bytes) == settings)
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(Set(object.keys) == ["searchDirectories", "executableOverrides", "awsProfiles", "timeout"])
}

@Test(arguments: [
    AuthSettings(searchDirectories: ["relative"]), AuthSettings(searchDirectories: ["/mis:bin"]),
    AuthSettings(executableOverrides: ["aws": "relative"]),
    AuthSettings(executableOverrides: ["": "/bin/aws"]), AuthSettings(searchDirectories: ["/bad\0path"]),
    AuthSettings(timeout: 0), AuthSettings(timeout: -1), AuthSettings(timeout: .infinity),
    AuthSettings(timeout: .nan), AuthSettings(timeout: 86_401),
    AuthSettings(awsProfiles: ["user": AWSProfileBinding(profile: "")]),
    AuthSettings(awsProfiles: ["user": AWSProfileBinding(profile: "--bad")]),
    AuthSettings(awsProfiles: ["user": AWSProfileBinding(profile: "dev", session: "\n")])
])
func authSettingsRejectInvalidValues(settings: AuthSettings) {
    #expect(throws: AuthenticationError.invalidSettings) { try settings.validate() }
}

@Test func credentialIdentityIncludesEffectiveSettingsExecutableAndEnvironment() throws {
    let context = try authContext()
    let base = try CredentialIdentity(from: context)
    let identities = try [
        CredentialIdentity(from: context, settings: AuthSettings(searchDirectories: ["/shims"])),
        CredentialIdentity(from: context, settings: AuthSettings(executableOverrides: ["aws": "/bin/aws"])),
        CredentialIdentity(from: context, settings: AuthSettings(awsProfiles: ["u": AWSProfileBinding(profile: "dev")])),
        CredentialIdentity(from: context, settings: AuthSettings(timeout: 800)),
        CredentialIdentity(from: context, executable: "/bin/aws"),
        CredentialIdentity(from: context, environment: ["SECRET": "synthetic-secret"])
    ]
    #expect(identities.allSatisfy { $0 != base })
    #expect(Set(identities).count == identities.count)
    let first = try CredentialIdentity(from: context, environment: ["A": "1", "B": "2"])
    let second = try CredentialIdentity(from: context, environment: ["B": "2", "A": "1"])
    #expect(first == second)
    var reflection = ""
    dump(identities, to: &reflection)
    #expect(!reflection.contains("synthetic-secret"))
}
