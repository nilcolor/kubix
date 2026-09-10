import Foundation
import KubixCore

/// Inject this CredentialProviding seam into app transports so requests also join explicit login.
/// CredentialProvider remains the lower-level cache/exec coordinator; neither service owns UI.
public actor AuthenticationService: AuthenticationControlling, CredentialProviding {
    private struct Operation {
        let work: SharedOperation<AcquiredCredential>
        let plan: CredentialPlan
        let loginKey: AWSLoginKey?
        let useDeviceCode: Bool
        var session: AuthSession
    }

    private let provider: CredentialProvider
    private let login: AWSLoginService
    private let deadline: any AuthDeadlineWaiting
    private var operations: [UUID: Operation] = [:]
    private var active: [CredentialIdentity: UUID] = [:]
    private var subscribers: [UUID: AsyncStream<AuthSession>.Continuation] = [:]

    public init(
        provider: CredentialProvider, login: AWSLoginService = AWSLoginService(),
        deadline: any AuthDeadlineWaiting = ContinuousAuthDeadline()
    ) {
        self.provider = provider
        self.login = login
        self.deadline = deadline
    }

    public func acquire(for context: ResolvedContext) async throws -> AcquiredCredential {
        try await acquire(for: context, progress: { _ in })
    }

    public func acquire(for context: ResolvedContext, progress: @escaping AuthProgress) async throws -> AcquiredCredential {
        let plan = try await provider.prepare(context)
        if let id = active[plan.identity], let operation = operations[id], !operation.work.isFinished {
            return try await operation.work.value(progress: progress)
        }
        let binding = plan.plugin.flatMap { try? AWSLoginBinding(context: context, plugin: $0) }
        if let binding, let ticket = await login.active(for: binding) {
            return try await begin(plan, binding: binding, ticket: ticket, useDeviceCode: false, progress: progress)
        }
        return try await begin(plan, binding: binding, progress: progress)
    }

    public func signIn(for context: ResolvedContext, useDeviceCode: Bool = false) async throws -> AcquiredCredential {
        let plan = try await provider.prepare(context)
        guard let plugin = plan.plugin else { throw AuthenticationError.unsupportedAWSInvocation }
        let binding = try AWSLoginBinding(context: context, plugin: plugin)
        if let id = active[plan.identity], let operation = operations[id],
           operation.loginKey != nil, !operation.work.isFinished {
            return try await operation.work.value()
        }
        let ticket = await login.operation(for: binding, useDeviceCode: useDeviceCode)
        return try await begin(plan, binding: binding, ticket: ticket, useDeviceCode: useDeviceCode)
    }

    public func invalidate(_ identity: CredentialIdentity, failedGeneration: CredentialCache.Generation) async {
        await provider.invalidate(identity, failedGeneration: failedGeneration)
    }

    public func update(settings: AuthSettings) async throws {
        try await provider.update(settings: settings)
    }

    public func presentation(for context: ResolvedContext) async -> AuthPluginPresentation {
        do {
            let plan = try await provider.prepare(context)
            guard let plugin = plan.plugin else { return AuthPluginPresentation() }
            do {
                let binding = try AWSLoginBinding(context: context, plugin: plugin)
                return AuthPluginPresentation(
                    executable: plugin.executable.path, source: plugin.source,
                    profile: binding.profile, canSignIn: true
                )
            } catch AuthenticationError.unsupportedAWSInvocation {
                return AuthPluginPresentation(executable: plugin.executable.path, source: plugin.source)
            } catch {
                return AuthPluginPresentation(
                    executable: plugin.executable.path, source: plugin.source, diagnostic: diagnostic(error)
                )
            }
        } catch { return AuthPluginPresentation(diagnostic: diagnostic(error)) }
    }

    public func sessions() -> AsyncStream<AuthSession> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AuthSession>.makeStream(bufferingPolicy: .bufferingNewest(64))
        subscribers[id] = continuation
        for operation in operations.values { continuation.yield(operation.session) }
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return stream
    }

    public func cancel(operationID: UUID) async {
        guard let operation = operations[operationID], !operation.session.state.isTerminal else { return }
        if let key = operation.loginKey {
            await login.cancel(key: key)
            for (id, affected) in operations where affected.loginKey == key && !affected.session.state.isTerminal {
                affected.work.cancel()
                finish(id, state: .cancelled)
            }
        } else {
            operation.work.cancel()
            finish(operationID, state: .cancelled)
        }
    }

    public func retry(operationID: UUID) async throws -> AcquiredCredential {
        guard let operation = operations[operationID] else { throw AuthenticationError.unknownOperation }
        if !operation.work.isFinished { return try await operation.work.value() }
        if operation.loginKey != nil {
            return try await signIn(for: operation.plan.context, useDeviceCode: operation.useDeviceCode)
        }
        return try await acquire(for: operation.plan.context)
    }

    private func begin(
        _ plan: CredentialPlan, binding: AWSLoginBinding? = nil, ticket: SharedOperation<Void>? = nil,
        useDeviceCode: Bool = false, progress: @escaping AuthProgress = { _ in }
    ) async throws -> AcquiredCredential {
        if let id = active[plan.identity], let existing = operations[id], !existing.work.isFinished,
           ticket == nil || existing.loginKey != nil {
            return try await existing.work.value(progress: progress)
        }
        let id = UUID()
        let session = AuthSession(
            id: id, credentialIdentity: plan.identity, provider: binding == nil ? "Credential plugin" : "AWS SSO",
            profile: binding?.profile, state: ticket == nil ? .acquiring : .waitingForBrowser
        )
        let work = SharedOperation<AcquiredCredential> { output in
            try await self.perform(id: id, plan: plan, ticket: ticket, output: output)
        }
        operations[id] = Operation(
            work: work, plan: plan, loginKey: ticket == nil ? nil : binding?.key,
            useDeviceCode: useDeviceCode, session: session
        )
        active[plan.identity] = id
        publish(session)
        // Bound retained retry metadata; terminal snapshots contain no instructions.
        if operations.count > 128, let oldest = operations.first(where: { $0.value.session.state.isTerminal })?.key {
            operations.removeValue(forKey: oldest)
        }
        return try await work.value(progress: progress)
    }

    private func perform(
        id: UUID, plan: CredentialPlan, ticket: SharedOperation<Void>?, output: @escaping AuthProgress
    ) async throws -> AcquiredCredential {
        let (chunks, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(32))
        let consumer = Task {
            for await text in chunks { self.append(text, to: id) }
        }
        let progress: AuthProgress = { text in
            output(text)
            continuation.yield(text)
        }
        do {
            let result = try await withAuthDeadline(seconds: plan.settings.timeout, clock: deadline) {
                try await self.authenticate(plan: plan, ticket: ticket, progress: progress)
            }
            try Task.checkCancellation()
            continuation.finish()
            await consumer.value
            finish(id, state: .succeeded)
            return result
        } catch {
            continuation.finish()
            await consumer.value
            finish(id, state: error is CancellationError ? .cancelled : .failed, diagnostic: diagnostic(error))
            throw error
        }
    }

    private func authenticate(
        plan: CredentialPlan, ticket: SharedOperation<Void>?, progress: @escaping AuthProgress
    ) async throws -> AcquiredCredential {
        if let ticket {
            try await ticket.value(progress: progress)
            try Task.checkCancellation()
            return try await provider.afterLogin(plan: plan, loginID: ticket.id, progress: progress)
        }
        return try await provider.acquire(plan: plan, progress: progress)
    }

    private func append(_ text: String, to id: UUID) {
        guard var operation = operations[id], !operation.session.state.isTerminal else { return }
        operation.session.append(text)
        operations[id] = operation
        publish(operation.session)
    }

    private func finish(_ id: UUID, state: AuthSession.State, diagnostic: String? = nil) {
        guard var operation = operations[id], !operation.session.state.isTerminal else { return }
        operation.session.transition(to: state, diagnostic: diagnostic)
        operations[id] = operation
        if active[operation.plan.identity] == id { active.removeValue(forKey: operation.plan.identity) }
        publish(operation.session)
    }

    private func diagnostic(_ error: any Error) -> String? {
        if error is CancellationError { return nil }
        if let error = error as? AuthError { return error.description }
        if let error = error as? AuthenticationError { return error.errorDescription }
        if let error = error as? ProcessFailure { return error.errorDescription }
        if let error = error as? PluginDiagnostic { return error.description }
        return "Authentication failed. Check the configured plugin/profile and explicitly retry."
    }

    private func publish(_ session: AuthSession) {
        for subscriber in subscribers.values { subscriber.yield(session) }
    }

    private func unsubscribe(_ id: UUID) { subscribers.removeValue(forKey: id) }

    func waiterCount(operationID: UUID) -> Int { operations[operationID]?.work.waiterCount ?? 0 }
}
