import Foundation
import KubixCore
import Testing

@Test func presentationIsLiveBeforeCompletionAndRedactsDiagnostics() throws {
    var session = try AuthSession(
        credentialIdentity: CredentialIdentity(from: appContext()), provider: "AWS SSO", profile: "synthetic",
        state: .waitingForBrowser
    )
    session.append("Open https://synthetic.invalid/login?code=fixture\nSYNTHETIC-DEVICE")
    let waiting = AuthPresentation(session)
    #expect(waiting.title == "AWS SSO — synthetic")
    #expect(waiting.instructions.contains("SYNTHETIC-DEVICE"))
    #expect(waiting.canCancel && !waiting.canRetry)
    #expect(waiting.authorizationURL?.scheme == "https")
    var reflection = ""
    dump(waiting, to: &reflection)
    #expect(!reflection.contains("SYNTHETIC-DEVICE") && !waiting.description.contains("fixture"))
    for state in [AuthSession.State.succeeded, .failed, .cancelled] {
        var terminal = session
        terminal.transition(to: state)
        let result = AuthPresentation(terminal)
        #expect(result.instructions.isEmpty && result.authorizationURL == nil && !result.canCancel)
        #expect(result.canRetry == (state != .succeeded))
    }
}

@MainActor private final class RecordingBrowser: BrowserOpening {
    var urls: [URL] = []
    var succeeds = true
    func open(_ url: URL) async -> Bool { urls.append(url); return succeeds }
}

@Suite @MainActor struct AuthPresentationActionTests {
    @Test func browserIsExplicitSafeAndUnavailableAfterCancellation() async throws {
        let browser = RecordingBrowser()
        let auth = AppTestAuth()
        let store = AppStore()
        let actions = AppActions(
            store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces(), browser: browser
        )
        defer { actions.shutdown() }
        try await appEventually { await auth.subscriberCount == 1 }
        var session = try AuthSession(credentialIdentity: CredentialIdentity(from: appContext()), provider: "Fake")
        session.append("http://synthetic.invalid/unsafe")
        await auth.emit(session)
        try await appEventually { store.authenticationSessions[session.id] != nil }
        await actions.openAuthorizationURL(operationID: session.id)
        #expect(browser.urls.isEmpty)
        session.append(" https://synthetic.invalid/safe")
        await auth.emit(session)
        try await appEventually { store.authenticationSessions[session.id]?.authorizationURL != nil }
        #expect(browser.urls.isEmpty)
        browser.succeeds = false
        await actions.openAuthorizationURL(operationID: session.id)
        #expect(browser.urls.count == 1)
        #expect(store.authenticationDiagnostic?.contains("browser could not be opened") == true)
        await actions.cancelAuthentication(operationID: session.id)
        await actions.openAuthorizationURL(operationID: session.id)
        #expect(browser.urls.count == 1)
        #expect(store.authenticationSessions[session.id]?.instructions.isEmpty == true)
    }

    @Test func explicitSignInResumesOnlyMatchingFailedOpenShells() async throws {
        let target = try appTarget()
        let auth = AppTestAuth()
        await auth.gate.open()
        await auth.fail(AuthenticationError.materialUnavailable)
        let store = AppStore(contexts: [target.context])
        let surfaces = AppTestSurfaces()
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: surfaces)
        defer { actions.shutdown() }
        let first = actions.openShell(target: target)
        let second = actions.openShell(target: target)
        let closed = actions.openShell(target: target)
        let other = actions.openShell(target: try appTarget("other"))
        try await appEventually { store.execSessions.allSatisfy { $0.state.isTerminal } }
        actions.closeShell(closed)
        await auth.fail(nil)
        try await actions.signIn(context: target.context, useDeviceCode: true)
        try await appEventually { surfaces.created[first] != nil && surfaces.created[second] != nil }
        #expect(surfaces.created[closed] == nil && surfaces.created[other] == nil)
        #expect(store.execSessions.count == 4)
        #expect(store.execSessions[0].target == target)
    }

    @Test func draftPreservesOtherUsersOverridesAndRejectsRelativePaths() throws {
        let context = try Kubeconfig(
            currentContext: "a", clusters: [.init(name: "a", cluster: .init(server: "https://synthetic.invalid"))],
            contexts: [.init(name: "a", context: .init(cluster: "a", user: "selected"))],
            users: [.init(name: "selected", user: .init(exec: .init(command: "aws", apiVersion: "client.authentication.k8s.io/v1")))]
        ).resolve()
        let settings = AuthSettings(executableOverrides: ["other": "/tools/other"], awsProfiles: ["other": .init(profile: "other")])
        var draft = AuthSettingsDraft(settings: settings, context: context)
        draft.searchDirectories = "/tools\n\n /shims "
        draft.executableOverride = "/selected/aws"
        draft.profile = "synthetic"
        let result = try draft.applying(to: settings, context: context)
        #expect(result.searchDirectories == ["/tools", "/shims"])
        #expect(result.executableOverrides == ["other": "/tools/other", "aws": "/selected/aws"])
        #expect(result.awsProfiles["other"] == settings.awsProfiles["other"])
        #expect(result.awsProfiles["selected"]?.profile == "synthetic")
        draft.executableOverride = "relative"
        #expect(throws: AuthenticationError.invalidSettings) { try draft.applying(to: settings, context: context) }
    }
}
