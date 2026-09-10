import Foundation
import KubixCore
import Testing

@Test(arguments: [AuthSession.State.succeeded, .failed, .cancelled])
func authSessionBoundsInstructionsAndClearsTerminalState(state: AuthSession.State) throws {
    let id = UUID()
    let identity = try CredentialIdentity(from: authContext())
    var session = AuthSession(id: id, credentialIdentity: identity, provider: "AWS SSO", profile: "dev")
    session.append(String(repeating: "x", count: 20_000))
    session.append("\nhttps://synthetic.invalid/authorize?code=synthetic-code\nDevice: ABCD")
    #expect(session.instructions.count == AuthSession.instructionLimit)
    #expect(session.authorizationURL?.host == "synthetic.invalid")
    session.transition(to: .waitingForBrowser)
    #expect(session.id == id)
    #expect(session.credentialIdentity == identity)
    var reflection = ""
    dump(session, to: &reflection)
    #expect(!reflection.contains("synthetic-code"))
    #expect(!session.description.contains("ABCD"))
    session.transition(to: state, diagnostic: "Sanitized diagnosis")
    #expect(session.instructions.isEmpty)
    #expect(session.authorizationURL == nil)
    session.append("late output")
    session.transition(to: .acquiring)
    #expect(session.state == state)
    #expect(session.instructions.isEmpty)
}

@Test(arguments: ["http://example.invalid/auth", "https://user:password@example.invalid/auth", "file:///local"])
func authSessionBrowserFallbackRequiresSafeHTTPS(url: String) throws {
    var session = AuthSession(credentialIdentity: try CredentialIdentity(from: authContext()), provider: "test")
    session.append(url)
    #expect(session.authorizationURL == nil)
}

@Test func authInstructionsBoundBytesEvenForCombiningMarksAndMultibyteScalars() {
    let text = "a" + String(repeating: "\u{301}", count: 30_000) + "😀€"
    let bounded = AuthSession.boundedInstructions(text)
    #expect(bounded.utf8.count <= AuthSession.instructionLimit)
    #expect(bounded.hasSuffix("😀€"))
    #expect(!bounded.contains("�"))
}
