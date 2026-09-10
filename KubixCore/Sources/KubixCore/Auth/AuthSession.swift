import Foundation

/// In-memory UI snapshot. Not Codable, and deliberately redacted in logs/reflection.
public struct AuthSession: Sendable, CustomStringConvertible, CustomReflectable {
    public enum State: Sendable {
        case acquiring, waitingForBrowser, succeeded, failed, cancelled

        public var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
    }

    public let id: UUID
    public let credentialIdentity: CredentialIdentity
    public let provider: String
    public let profile: String?
    public private(set) var state: State
    public private(set) var instructions = ""
    public private(set) var diagnostic: String?
    public static let instructionLimit = 8_192
    public var description: String { "AuthSession \(id) (\(state), contents redacted)" }
    public var customMirror: Mirror { Mirror(self, children: ["id": id, "contents": "redacted"]) }

    public init(
        id: UUID = UUID(), credentialIdentity: CredentialIdentity, provider: String,
        profile: String? = nil, state: State = .acquiring
    ) {
        self.id = id
        self.credentialIdentity = credentialIdentity
        self.provider = provider
        self.profile = profile
        self.state = state
    }

    public mutating func append(_ text: String) {
        guard !state.isTerminal else { return }
        instructions = Self.boundedInstructions(instructions + text)
    }

    /// Bound UTF-8 bytes, not grapheme count (one grapheme can contain unbounded combining marks).
    public static func boundedInstructions(_ text: String) -> String {
        var bytes = Array(text.utf8.suffix(instructionLimit))
        while let first = bytes.first, first & 0xC0 == 0x80 { bytes.removeFirst() }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Only sanitized application diagnostics belong here, never raw process output/errors.
    public mutating func transition(to state: State, diagnostic: String? = nil) {
        guard !self.state.isTerminal else { return }
        self.state = state
        self.diagnostic = diagnostic
        if state.isTerminal { instructions = "" }
    }

    /// The app adapter may offer this fallback; core/runtime never launches a browser.
    public var authorizationURL: URL? {
        instructions.components(separatedBy: .whitespacesAndNewlines).compactMap {
            URL(string: $0.trimmingCharacters(in: CharacterSet(charactersIn: "()<>\"'")))
        }.first { $0.scheme?.lowercased() == "https" && $0.host != nil && $0.user == nil && $0.password == nil }
    }
}
