import Foundation

/// Only user-selected, nonsecret configuration is persistable. Never put environment values here.
public struct AuthSettings: Codable, Equatable, Sendable {
    public var searchDirectories: [String]
    public var executableOverrides: [String: String]
    /// Keys are kubeconfig user names, not context display names.
    public var awsProfiles: [String: AWSProfileBinding]
    public var timeout: TimeInterval

    public init(
        searchDirectories: [String] = [], executableOverrides: [String: String] = [:],
        awsProfiles: [String: AWSProfileBinding] = [:], timeout: TimeInterval = 600
    ) {
        self.searchDirectories = searchDirectories
        self.executableOverrides = executableOverrides
        self.awsProfiles = awsProfiles
        self.timeout = timeout
    }

    public func validate() throws {
        guard timeout.isFinite, timeout > 0, timeout <= 86_400,
              searchDirectories.allSatisfy({ Self.absolutePath($0) && !$0.contains(":") }),
              executableOverrides.allSatisfy({ !$0.key.isEmpty && Self.absolutePath($0.value) }),
              awsProfiles.allSatisfy({ !$0.key.isEmpty && $0.value.isValid }) else {
            throw AuthenticationError.invalidSettings
        }
    }

    private static func absolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0")
    }
}

public struct AWSProfileBinding: Codable, Equatable, Sendable {
    public var profile: String
    /// Optional already-resolved SSO session binding; the runtime never reads AWS config to guess it.
    public var session: String?

    public init(profile: String, session: String? = nil) {
        self.profile = profile
        self.session = session
    }

    var isValid: Bool {
        Self.validName(profile) && (session.map(Self.validName) ?? true)
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

public enum AuthenticationError: Error, Equatable, Sendable, LocalizedError {
    case invalidSettings
    case settingsUnavailable
    case unsupportedCertificate
    case materialUnavailable
    case missingAWSProfile
    case conflictingAWSProfile
    case unsupportedAWSInvocation
    case requiresAWSCLIV2
    case unknownOperation

    public var errorDescription: String? {
        switch self {
        case .invalidSettings: "Select absolute plugin paths, valid profile bindings, and a positive auth timeout (at most one day)."
        case .settingsUnavailable: "Authentication settings could not be loaded or saved."
        case .unsupportedCertificate:
            "Client certificate authentication (static or exec-returned) is unsupported in v0.1. Use bearer-token credentials."
        case .materialUnavailable: "The configured authentication material could not be read."
        case .missingAWSProfile: "Bind an already-configured AWS SSO profile before signing in. Profile setup is a prerequisite."
        case .conflictingAWSProfile: "AWS profile bindings conflict. Align the exec arguments, environment, and app settings."
        case .unsupportedAWSInvocation: "Sign in requires a direct AWS CLI eks get-token invocation, not an unknown wrapper."
        case .requiresAWSCLIV2: "Browser sign-in requires AWS CLI v2. Install AWS CLI v2 or configure its absolute executable path."
        case .unknownOperation: "This authentication operation is no longer available."
        }
    }
}
