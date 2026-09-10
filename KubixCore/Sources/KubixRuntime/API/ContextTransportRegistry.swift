import Foundation
import KubixCore

/// Keys include the complete immutable context snapshot, not its mutable picker name.
public actor ContextTransportRegistry {
    public typealias Factory = @Sendable (ResolvedContext) async throws -> any Transport
    private struct Entry {
        let context: ResolvedContext
        let task: Task<any Transport, any Error>
        let id: UUID
    }
    private var entries: [Entry] = []
    private let factory: Factory

    public init(factory: @escaping Factory) { self.factory = factory }

    public init(credentials: any CredentialProviding, warning: @escaping @Sendable (String) -> Void) {
        factory = { context in
            try await URLSessionTransport(context: context, credentials: credentials, warning: warning)
        }
    }

    public func transport(for context: ResolvedContext) async throws -> any Transport {
        if let entry = entries.first(where: { $0.context == context }) { return try await entry.task.value }
        let id = UUID()
        let task = Task { [factory] in try await factory(context) }
        entries.append(Entry(context: context, task: task, id: id))
        do { return try await task.value } catch {
            entries.removeAll { $0.id == id }
            throw error
        }
    }

    public func shutdown() {
        for entry in entries { entry.task.cancel() }
        entries.removeAll()
    }
}
