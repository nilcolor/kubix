import Foundation

/// Only the transient session's approved progress channel enters this presentation, never credentials.
public struct AuthPresentation: Sendable, CustomStringConvertible, CustomReflectable {
    public let session: AuthSession
    public var title: String { session.profile.map { "\(session.provider) — \($0)" } ?? session.provider }
    public var instructions: String { session.state.isTerminal ? "" : session.instructions }
    public var authorizationURL: URL? { session.state.isTerminal ? nil : session.authorizationURL }
    public var canCancel: Bool { !session.state.isTerminal }
    public var canRetry: Bool { session.state == .failed || session.state == .cancelled }
    public var status: String {
        switch session.state {
        case .acquiring: "Acquiring credentials"
        case .waitingForBrowser: "Waiting for browser sign-in"
        case .succeeded: "Credentials ready"
        case .failed: session.diagnostic ?? "Authentication failed"
        case .cancelled: "Authentication cancelled"
        }
    }
    public init(_ session: AuthSession) { self.session = session }
    public var description: String { "AuthPresentation(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Resolver diagnostics deliberately omit the effective environment and command arguments.
public struct AuthPluginPresentation: Equatable, Sendable {
    public let executable: String?
    public let source: String?
    public let profile: String?
    public let diagnostic: String?
    public let canSignIn: Bool

    public init(
        executable: String? = nil, source: String? = nil, profile: String? = nil,
        diagnostic: String? = nil, canSignIn: Bool = false
    ) {
        self.executable = executable
        self.source = source
        self.profile = profile
        self.diagnostic = diagnostic
        self.canSignIn = canSignIn
    }
}

public struct AuthSettingsDraft: Equatable, Sendable {
    public var searchDirectories: String
    public var executableOverride: String
    public var profile: String
    public var session: String

    public init(settings: AuthSettings, context: ResolvedContext?) {
        searchDirectories = settings.searchDirectories.joined(separator: "\n")
        executableOverride = context?.user?.exec.flatMap { settings.executableOverrides[$0.command] } ?? ""
        let binding = context?.userName.flatMap { settings.awsProfiles[$0] }
        profile = binding?.profile ?? ""
        session = binding?.session ?? ""
    }

    public func applying(to settings: AuthSettings, context: ResolvedContext?) throws -> AuthSettings {
        var result = settings
        result.searchDirectories = searchDirectories.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let command = context?.user?.exec?.command {
            result.executableOverrides[command] = executableOverride.isEmpty ? nil : executableOverride
        }
        if let user = context?.userName {
            result.awsProfiles[user] = profile.isEmpty ? nil : AWSProfileBinding(
                profile: profile, session: session.isEmpty ? nil : session
            )
        }
        try result.validate()
        return result
    }
}
