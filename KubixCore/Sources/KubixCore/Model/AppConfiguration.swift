import Foundation

public protocol AppConfigurationLoading: Sendable {
    func load() async -> AppConfiguration
}

public struct AppConfiguration: Sendable {
    public var contexts: [ResolvedContext] = []
    public var preferredContext: String?
    public var diagnostics: [String] = []
    public var settings: AuthSettings?

    public init(configuration: Kubeconfig?, settings: AuthSettings?, diagnostics: [String] = []) {
        self.settings = settings
        self.diagnostics = diagnostics
        guard let configuration else { return }
        preferredContext = configuration.currentContext
        for item in configuration.contexts {
            do { contexts.append(try configuration.resolve(context: item.name)) } catch {
                let message = (error as? KubeconfigError)?.description ?? "Context could not be resolved."
                self.diagnostics.append("\(item.name): \(message)")
            }
        }
        if configuration.contexts.isEmpty { self.diagnostics.append("Kubeconfig contains no configured contexts.") }
        if let preferredContext, !configuration.contexts.contains(where: { $0.name == preferredContext }) {
            self.diagnostics.append("The kubeconfig current-context does not name a configured context. Select one explicitly.")
        }
    }
}
