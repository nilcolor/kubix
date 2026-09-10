import Foundation
import KubixCore

/// Filesystem IO stays off the main actor; neither load nor presentation executes a credential plugin.
public actor AppConfigurationLoader: AppConfigurationLoading {
    private let loader: KubeconfigLoader
    private let settings: any AuthSettingsStoring

    public init(loader: KubeconfigLoader, settings: any AuthSettingsStoring) {
        self.loader = loader
        self.settings = settings
    }

    public func load() async -> AppConfiguration {
        var diagnostics: [String] = []
        var configuration: Kubeconfig?
        var loadedSettings: AuthSettings?
        do { configuration = try loader.load() } catch {
            diagnostics.append((error as? KubeconfigError)?.description ?? "Kubeconfig could not be loaded.")
        }
        do { loadedSettings = try await settings.load() } catch {
            diagnostics.append(AuthenticationError.settingsUnavailable.errorDescription!)
        }
        return AppConfiguration(configuration: configuration, settings: loadedSettings, diagnostics: diagnostics)
    }
}
