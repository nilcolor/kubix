import Foundation
import KubixCore

public actor AWSLoginService {
    private let runner: any ProcessRunning
    private let owner = SharedOperationOwner<Void>()
    private var flights: [AWSLoginKey: SharedOperation<Void>] = [:]

    public init(runner: any ProcessRunning = ProcessRunner()) { self.runner = runner }

    public func login(
        _ binding: AWSLoginBinding, useDeviceCode: Bool = false, progress: @escaping AuthProgress = { _ in }
    ) async throws {
        try await operation(for: binding, useDeviceCode: useDeviceCode).value(progress: progress)
    }

    func active(for binding: AWSLoginBinding) -> SharedOperation<Void>? {
        guard let operation = flights[binding.key], !operation.isFinished else { return nil }
        return operation
    }

    func operation(for binding: AWSLoginBinding, useDeviceCode: Bool) throws -> SharedOperation<Void> {
        try owner.checkOpen()
        if let operation = active(for: binding) { return operation }
        let operation = try owner.make { [runner] progress in
            let start = ContinuousClock.now
            let version = try await runner.run(ProcessRequest(
                executable: binding.executable, arguments: ["--version"], environment: binding.environment,
                timeout: min(5, binding.timeout)
            ), progress: { _ in })
            guard version.exitCode == 0, String(decoding: version.stdout, as: UTF8.self).hasPrefix("aws-cli/2.") else {
                throw AuthenticationError.requiresAWSCLIV2
            }
            try Task.checkCancellation()
            let elapsed = start.duration(to: .now).components
            let remaining = binding.timeout - Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18
            guard remaining > 0 else { throw ProcessFailure.timedOut }
            var args = ["sso", "login", "--profile", binding.profile, "--no-cli-pager", "--no-cli-auto-prompt"]
            if useDeviceCode { args.append("--use-device-code") }
            let result = try await runner.run(ProcessRequest(
                executable: binding.executable, arguments: args + binding.options, environment: binding.environment,
                timeout: remaining, output: .instructions
            ), progress: progress)
            guard result.exitCode == 0 else { throw ProcessFailure.exited(result.exitCode) }
        }
        flights[binding.key] = operation
        return operation
    }

    func cancel(key: AWSLoginKey) { flights[key]?.cancel() }

    public func cancel(_ binding: AWSLoginBinding) { cancel(key: binding.key) }

    public func shutdown() async {
        await owner.shutdown()
        flights.removeAll()
    }
}
