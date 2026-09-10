import Foundation
import Yams

public protocol KubeconfigFileSystem: Sendable {
    /// Return nil only for an absent file; other failures must throw.
    func readFile(at url: URL) throws -> Data?
}

public struct LocalKubeconfigFileSystem: KubeconfigFileSystem {
    public init() {}

    public func readFile(at url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return nil
        }
    }
}

public struct KubeconfigLoader: Sendable {
    private let configuredPaths: String?
    private let homeDirectory: URL
    private let workingDirectory: URL
    private let fileSystem: any KubeconfigFileSystem

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        fileSystem: any KubeconfigFileSystem = LocalKubeconfigFileSystem()
    ) {
        configuredPaths = environment["KUBECONFIG"].flatMap { $0.isEmpty ? nil : $0 }
        self.homeDirectory = homeDirectory
        self.workingDirectory = workingDirectory
        self.fileSystem = fileSystem
    }

    public func load() throws -> Kubeconfig {
        let paths = configuredPaths?.split(separator: ":").map(String.init) ?? ["~/.kube/config"]
        var visited = Set<URL>()
        var foundFile = false
        var merged = Kubeconfig()
        for path in paths {
            let source = try resolvePath(path, relativeTo: workingDirectory)
            guard visited.insert(source).inserted else { continue }
            guard let data = try readConfiguration(at: source) else { continue }
            foundFile = true
            var config = try decode(data)
            try validateNames(config.clusters.map(\.name))
            try validateNames(config.contexts.map(\.name))
            try validateNames(config.users.map(\.name))
            for index in config.clusters.indices { config.clusters[index].sourceFile = source }
            for index in config.contexts.indices { config.contexts[index].sourceFile = source }
            for index in config.users.indices { config.users[index].sourceFile = source }
            merge(config, into: &merged)
        }
        guard foundFile else { throw KubeconfigError.configurationNotFound }
        try resolvePaths(in: &merged)
        return merged
    }

    private func readConfiguration(at url: URL) throws -> Data? {
        do {
            return try fileSystem.readFile(at: url)
        } catch {
            // Filesystem and YAML errors can embed credentials or snippets of the source.
            throw KubeconfigError.unreadableFile
        }
    }

    private func decode(_ data: Data) throws -> Kubeconfig {
        do {
            guard let yaml = String(data: data, encoding: .utf8) else { throw KubeconfigError.malformedYAML }
            let parser = try Parser(yaml: yaml, resolver: .basic.appending(.merge))
            // Yams nodes hold weak anchor references; keep the parser alive through decoding.
            return try withExtendedLifetime(parser) {
                guard let node = try parser.singleRoot() else { return Kubeconfig() }
                try validateMappingKeys(in: node)
                return try YAMLDecoder().decode(Kubeconfig?.self, from: node) ?? Kubeconfig()
            }
        } catch {
            throw KubeconfigError.malformedYAML
        }
    }

    private func validateMappingKeys(in root: Node) throws {
        var pending = [root]
        while let node = pending.popLast() {
            switch node {
            case .mapping(let mapping):
                var keys = Set<String>()
                for (key, value) in mapping {
                    guard let key = key.string, keys.insert(key).inserted else {
                        throw KubeconfigError.malformedYAML
                    }
                    pending.append(value)
                }
            case .sequence(let sequence):
                pending.append(contentsOf: sequence)
            case .scalar, .alias:
                break
            }
        }
    }

    private func validateNames(_ names: [String]) throws {
        guard !names.contains(""), Set(names).count == names.count else {
            throw KubeconfigError.invalidEntryNames
        }
    }

    private func merge(_ config: Kubeconfig, into merged: inout Kubeconfig) {
        if merged.apiVersion?.isEmpty != false { merged.apiVersion = config.apiVersion }
        if merged.kind?.isEmpty != false { merged.kind = config.kind }
        if merged.currentContext?.isEmpty != false { merged.currentContext = config.currentContext }
        appendFirstWins(config.clusters, to: &merged.clusters, name: \.name)
        appendFirstWins(config.contexts, to: &merged.contexts, name: \.name)
        appendFirstWins(config.users, to: &merged.users, name: \.name)
    }

    private func appendFirstWins<Entry>(_ entries: [Entry], to merged: inout [Entry], name: KeyPath<Entry, String>) {
        var names = Set(merged.map { $0[keyPath: name] })
        merged.append(contentsOf: entries.filter { names.insert($0[keyPath: name]).inserted })
    }

    private func resolvePaths(in config: inout Kubeconfig) throws {
        for index in config.clusters.indices {
            let directory = config.clusters[index].sourceFile?.deletingLastPathComponent() ?? workingDirectory
            config.clusters[index].cluster.certificateAuthority = try resolveOptionalPath(
                config.clusters[index].cluster.certificateAuthority, relativeTo: directory
            )
        }
        for index in config.users.indices {
            let directory = config.users[index].sourceFile?.deletingLastPathComponent() ?? workingDirectory
            var user = config.users[index].user
            user.tokenFile = try resolveOptionalPath(user.tokenFile, relativeTo: directory)
            user.clientCertificate = try resolveOptionalPath(user.clientCertificate, relativeTo: directory)
            user.clientKey = try resolveOptionalPath(user.clientKey, relativeTo: directory)
            if let command = user.exec?.command, command.contains("/") || command.hasPrefix("~") {
                user.exec?.command = try resolvePath(command, relativeTo: directory).path
            }
            config.users[index].user = user
        }
    }

    private func resolveOptionalPath(_ path: String?, relativeTo directory: URL) throws -> String? {
        guard let path, !path.isEmpty else { return path }
        return try resolvePath(path, relativeTo: directory).path
    }

    private func resolvePath(_ path: String, relativeTo directory: URL) throws -> URL {
        if path == "~" { return homeDirectory.standardizedFileURL }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)), isDirectory: false).standardizedFileURL
        }
        guard !path.hasPrefix("~") else { throw KubeconfigError.unsupportedHomeReference }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL }
        return directory.appendingPathComponent(path, isDirectory: false).standardizedFileURL
    }
}

/// Diagnostics deliberately contain no raw YAML, paths, URLs, tokens, or plugin environment values.
public enum KubeconfigError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case configurationNotFound
    case unreadableFile
    case malformedYAML
    case invalidEntryNames
    case unsupportedHomeReference
    case missingCurrentContext
    case unknownContext
    case missingClusterReference
    case unknownCluster
    case unknownUser
    case invalidServer
    case unsupportedProxy
    case unsupportedAuthentication

    public var description: String {
        switch self {
        case .configurationNotFound:
            "No kubeconfig file was found. Set KUBECONFIG or create ~/.kube/config."
        case .unreadableFile:
            "A kubeconfig file could not be read. Check its permissions and file type."
        case .malformedYAML:
            "A kubeconfig file contains malformed YAML or invalid field types."
        case .invalidEntryNames:
            "Kubeconfig entries must have nonempty, unique names within each file."
        case .unsupportedHomeReference:
            "Kubeconfig paths support ~ and ~/ for the current home directory, not ~user."
        case .missingCurrentContext:
            "No current-context is configured. Select a context explicitly."
        case .unknownContext:
            "The selected context is not defined in the merged kubeconfig."
        case .missingClusterReference:
            "The selected context does not name a cluster."
        case .unknownCluster:
            "The selected context references a cluster that is not defined."
        case .unknownUser:
            "The selected context references a user that is not defined."
        case .invalidServer:
            "The selected cluster requires an HTTP(S) server URL without embedded credentials."
        case .unsupportedProxy:
            "Kubeconfig proxy-url is unsupported. This context cannot be activated; no direct connection will be made."
        case .unsupportedAuthentication:
            "This context uses unsupported auth-provider, basic authentication or impersonation. Use a supported bearer-token configuration."
        }
    }

    public var errorDescription: String? { description }
}
