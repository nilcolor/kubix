import Foundation
import KubixCore
import Testing

/// Which live credential work is worth interrupting a page for, as opposed to merely being on record.
@Suite @MainActor struct AuthAttentionTests {
    @Test func aFinishedSignInIsNotWorthTheUsersAttentionButAnUnfinishedOneIs() async throws {
        let auth = AppTestAuth()
        let context = try appContext()
        let store = AppStore(contexts: [context])
        let actions = AppActions(store: store, exec: AppTestExec(), authentication: auth, surfaces: AppTestSurfaces())
        defer { actions.shutdown() }
        try await appEventually { await auth.subscriberCount == 1 }
        let identity = try CredentialIdentity(from: context)
        let done = AuthSession(credentialIdentity: identity, provider: "Synthetic", state: .succeeded)
        await auth.emit(done)
        try await appEventually { store.authenticationSessions[done.id] != nil }
        #expect(store.focusedAuthenticationSessions.map(\.id) == [done.id])
        #expect(store.attentionAuthenticationSessions.isEmpty)

        // A plugin refreshing a token needs nothing from the user and must not draw anything.
        let refreshing = AuthSession(credentialIdentity: identity, provider: "Synthetic")
        await auth.emit(refreshing)
        try await appEventually { store.authenticationSessions[refreshing.id]?.state == .acquiring }
        #expect(store.attentionAuthenticationSessions.isEmpty)

        var waiting = AuthSession(credentialIdentity: identity, provider: "Synthetic")
        waiting.transition(to: .waitingForBrowser)
        await auth.emit(waiting)
        try await appEventually { store.authenticationSessions[waiting.id]?.state == .waitingForBrowser }
        #expect(store.attentionAuthenticationSessions.map(\.id) == [waiting.id])

        var failed = AuthSession(credentialIdentity: identity, provider: "Synthetic")
        failed.transition(to: .failed, diagnostic: "Configured plugin failed.")
        await auth.emit(failed)
        try await appEventually { store.authenticationSessions[failed.id]?.state == .failed }
        #expect(store.attentionAuthenticationSessions.map(\.id) == [waiting.id, failed.id])

        // Terminal sessions coalesce to the newest per identity, so a cancellation displaces the
        // failure rather than joining it, and neither of them wants anything from the user.
        var cancelled = AuthSession(credentialIdentity: identity, provider: "Synthetic")
        cancelled.transition(to: .cancelled)
        await auth.emit(cancelled)
        try await appEventually { store.authenticationSessions[cancelled.id]?.state == .cancelled }
        // Still on record — it is the attention list it stays out of.
        #expect(store.visibleAuthenticationSessions.map(\.id) == [refreshing.id, waiting.id, cancelled.id])
        #expect(store.attentionAuthenticationSessions.map(\.id) == [waiting.id])
    }
}
