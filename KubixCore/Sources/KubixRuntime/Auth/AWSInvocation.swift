import Foundation
import KubixCore

/// Recognize only the documented direct invocation; never invent recovery commands for wrappers.
struct AWSInvocation: Sendable {
    let profiles: [String]
    let loginOptions: [String]

    init(configuration: KubeconfigExec) throws {
        guard URL(fileURLWithPath: configuration.command).lastPathComponent == "aws" else {
            throw AuthenticationError.unsupportedAWSInvocation
        }
        let valued: Set<String> = [
            "--profile", "--region", "--ca-bundle", "--endpoint-url", "--output", "--cli-binary-format",
            "--cluster-name", "--cluster-id", "--role-arn", "--cli-connect-timeout", "--cli-read-timeout"
        ]
        let flags: Set<String> = ["--no-cli-pager", "--no-cli-auto-prompt", "--no-verify-ssl"]
        let shared: Set<String> = ["--region", "--ca-bundle", "--endpoint-url", "--cli-connect-timeout", "--cli-read-timeout"]
        let args = configuration.args ?? []
        var positionals: [String] = []
        var profiles: [String] = []
        var options: [String] = []
        var index = 0
        while index < args.count {
            let parts = args[index].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = parts[0]
            if valued.contains(name) {
                let value = try Self.optionValue(parts, args: args, index: &index)
                if name == "--profile" { profiles.append(value) }
                if shared.contains(name) { options += [name, value] }
            } else if flags.contains(name), parts.count == 1 {
                if name == "--no-verify-ssl" { options.append(name) }
            } else {
                guard !name.hasPrefix("-"), parts.count == 1 else { throw AuthenticationError.unsupportedAWSInvocation }
                positionals.append(name)
            }
            index += 1
        }
        guard positionals == ["eks", "get-token"] else { throw AuthenticationError.unsupportedAWSInvocation }
        self.profiles = profiles
        loginOptions = options
    }

    private static func optionValue(_ parts: [String], args: [String], index: inout Int) throws -> String {
        let value: String
        if parts.count == 2 {
            value = parts[1]
        } else {
            index += 1
            guard index < args.count else { throw AuthenticationError.unsupportedAWSInvocation }
            value = args[index]
        }
        guard !value.isEmpty, !value.hasPrefix("--") else { throw AuthenticationError.unsupportedAWSInvocation }
        return value
    }

    func profile(environment: [String: String], binding: AWSProfileBinding?) throws -> String {
        let values = profiles + [environment["AWS_PROFILE"], environment["AWS_DEFAULT_PROFILE"], binding?.profile]
            .compactMap { $0 }.filter { !$0.isEmpty }
        guard let profile = values.first else { throw AuthenticationError.missingAWSProfile }
        guard Set(values).count == 1 else { throw AuthenticationError.conflictingAWSProfile }
        try AuthSettings(awsProfiles: ["selected": AWSProfileBinding(profile: profile)]).validate()
        return profile
    }
}

struct AWSLoginKey: Hashable, Sendable, CustomStringConvertible, CustomReflectable {
    private let configuration: Data
    var description: String { "AWSLoginKey (redacted)" }
    var customMirror: Mirror { Mirror(self, children: ["contents": "redacted"]) }

    init(executable: URL, profile: String, session: String?, environment: [String: String], options: [String]) throws {
        var environment = environment
        if session != nil {
            environment.removeValue(forKey: "AWS_PROFILE")
            environment.removeValue(forKey: "AWS_DEFAULT_PROFILE")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        configuration = try encoder.encode([
            "executable": [executable.path], "binding": [session == nil ? "profile" : "session", session ?? profile],
            "environment": environment.keys.sorted().flatMap { [$0, environment[$0]!] }, "options": options
        ])
    }
}

public struct AWSLoginBinding: Sendable, CustomStringConvertible, CustomReflectable {
    public let profile: String
    public let session: String?
    public let executable: URL
    let environment: [String: String]
    let options: [String]
    let timeout: TimeInterval
    let key: AWSLoginKey
    public var description: String { "AWSLoginBinding (redacted)" }
    public var customMirror: Mirror { Mirror(self, children: ["contents": "redacted"]) }

    public init(context: ResolvedContext, plugin: ResolvedPlugin) throws {
        guard let configuration = context.user?.exec else { throw AuthenticationError.unsupportedAWSInvocation }
        let invocation = try AWSInvocation(configuration: configuration)
        let setting = context.userName.flatMap { plugin.settings.awsProfiles[$0] }
        profile = try invocation.profile(environment: plugin.environment, binding: setting)
        session = setting?.session
        executable = plugin.executable
        var environment = plugin.environment
        environment["AWS_PROFILE"] = profile
        environment["AWS_PAGER"] = ""
        environment["AWS_CLI_AUTO_PROMPT"] = "off"
        // ExecCredential input must not be inherited by the separate login/version commands.
        environment.removeValue(forKey: "KUBERNETES_EXEC_INFO")
        self.environment = environment
        options = invocation.loginOptions
        timeout = plugin.settings.timeout
        key = try AWSLoginKey(
            executable: executable, profile: profile, session: session,
            environment: environment, options: options
        )
    }
}
