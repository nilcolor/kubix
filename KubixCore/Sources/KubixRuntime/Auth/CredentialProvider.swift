import Foundation
import KubixCore

struct CredentialPlan: Sendable {
    let context: ResolvedContext
    let method: AuthMethod
    let identity: CredentialIdentity
    let plugin: ResolvedPlugin?
    let settings: AuthSettings
}

public actor CredentialProvider: CredentialProviding {
    private let resolver: PluginResolver
    private let runner: CredentialRunner
    private let materials: any AuthMaterialReading
    private var cache: CredentialCache
    private var flights: [CredentialIdentity: SharedOperation<AcquiredCredential>] = [:]
    private var loginRefreshes: [CredentialIdentity: (id: UUID, work: SharedOperation<AcquiredCredential>)] = [:]

    public init(
        resolver: PluginResolver, runner: CredentialRunner = CredentialRunner(),
        materials: any AuthMaterialReading = LocalAuthMaterialReader(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.resolver = resolver
        self.runner = runner
        self.materials = materials
        cache = CredentialCache(now: now)
    }

    public func acquire(for context: ResolvedContext, progress: @escaping AuthProgress) async throws -> AcquiredCredential {
        try await acquire(plan: prepare(context), progress: progress)
    }

    func update(settings: AuthSettings) async throws {
        try await resolver.update(settings: settings)
    }

    func prepare(_ context: ResolvedContext) async throws -> CredentialPlan {
        let method = try AuthMethod.resolve(from: context)
        let plugin: ResolvedPlugin?
        let settings: AuthSettings
        if case .exec(let configuration) = method {
            let resolved = try await resolver.resolve(configuration, sourceFile: context.userSourceFile, userName: context.userName)
            plugin = resolved
            settings = resolved.settings
        } else {
            plugin = nil
            settings = try await resolver.settings()
        }
        return CredentialPlan(
            context: context, method: method,
            identity: try CredentialIdentity(
                from: context, settings: settings, executable: plugin?.executable.path, environment: plugin?.environment ?? [:]
            ), plugin: plugin, settings: settings
        )
    }

    func acquire(plan: CredentialPlan, progress: @escaping AuthProgress) async throws -> AcquiredCredential {
        try Task.checkCancellation()
        if case .fresh(let entry) = cache.lookup(for: plan.identity) {
            return AcquiredCredential(identity: plan.identity, entry: entry)
        }
        if let operation = flights[plan.identity], !operation.isFinished {
            return try await operation.value(progress: progress)
        }
        let operation = SharedOperation<AcquiredCredential> { output in
            try await self.perform(plan, progress: output)
        }
        flights[plan.identity] = operation
        do {
            let value = try await operation.value(progress: progress)
            if flights[plan.identity]?.id == operation.id { flights.removeValue(forKey: plan.identity) }
            return value
        } catch {
            if operation.isFinished, flights[plan.identity]?.id == operation.id {
                flights.removeValue(forKey: plan.identity)
            }
            throw error
        }
    }

    public func invalidate(_ identity: CredentialIdentity, failedGeneration: CredentialCache.Generation) {
        cache.invalidate(identity, generation: failedGeneration)
    }

    private func generation(for identity: CredentialIdentity) -> CredentialCache.Generation? {
        switch cache.lookup(for: identity) {
        case .fresh(let entry), .refreshDue(let entry), .expired(let entry): entry.generation
        case .missing: nil
        }
    }

    /// Rotate once per successful login, even with several callers and a pre-login refresh in flight.
    func afterLogin(plan: CredentialPlan, loginID: UUID, progress: @escaping AuthProgress) async throws -> AcquiredCredential {
        if let refresh = loginRefreshes[plan.identity], refresh.id == loginID {
            return try await refresh.work.value(progress: progress)
        }
        let work = SharedOperation<AcquiredCredential> { output in
            if let old = await self.pending(for: plan.identity) {
                _ = try? await old.value()
            }
            try Task.checkCancellation()
            await self.invalidateCurrent(plan.identity)
            return try await self.acquire(plan: plan, progress: output)
        }
        loginRefreshes[plan.identity] = (loginID, work)
        return try await work.value(progress: progress)
    }

    private func pending(for identity: CredentialIdentity) -> SharedOperation<AcquiredCredential>? {
        guard let work = flights[identity], !work.isFinished else { return nil }
        return work
    }

    private func invalidateCurrent(_ identity: CredentialIdentity) {
        if let generation = generation(for: identity) { cache.invalidate(identity, generation: generation) }
    }

    private func perform(_ plan: CredentialPlan, progress: @escaping AuthProgress) async throws -> AcquiredCredential {
        let credential: Credential
        switch plan.method {
        case .token(let token): credential = try Credential(token: token)
        case .tokenFile(let path):
            let data = try await materials.read(path)
            guard let token = String(data: data, encoding: .utf8) else { throw AuthError.invalidToken }
            credential = try Credential(token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        case .anonymous: return AcquiredCredential(identity: plan.identity, entry: nil)
        case .clientCertificate: throw AuthenticationError.unsupportedCertificate
        case .exec:
            guard let plugin = plan.plugin else { throw AuthError.invalidConfiguration }
            credential = try await runner.acquire(context: plan.context, plugin: plugin, progress: progress)
        }
        try Task.checkCancellation()
        guard credential.clientCertificateData == nil else { throw AuthenticationError.unsupportedCertificate }
        return AcquiredCredential(identity: plan.identity, entry: try cache.store(credential, for: plan.identity))
    }
}
