import Foundation

/// Deliberately not Codable: no raw spec, environment, arbitrary annotations or status messages are retained.
public struct PodDetails: Decodable, Equatable, Sendable {
    public enum ContainerKind: String, Sendable { case regular, initContainer = "init", ephemeral }
    public enum ContainerState: String, Sendable { case running, waiting, terminated, unknown }
    public struct Container: Equatable, Sendable {
        public let name: String
        public let kind: ContainerKind
        public let state: ContainerState
    }

    public let uid: String
    public let name: String
    public let namespace: String
    public let defaultContainer: String?
    public let containers: [Container]

    private enum CodingKeys: String, CodingKey { case apiVersion, kind, metadata, spec, status }
    private struct Metadata: Decodable {
        let uid: String
        let name: String
        let namespace: String
        let annotations: Annotation?
    }
    private struct Annotation: Decodable {
        let defaultContainer: String?
        enum CodingKeys: String, CodingKey { case defaultContainer = "kubectl.kubernetes.io/default-container" }
    }
    private struct Declaration: Decodable { let name: String }
    private struct Spec: Decodable {
        let containers: [Declaration]
        let initContainers: [Declaration]?
        let ephemeralContainers: [Declaration]?
    }
    private struct Status: Decodable {
        let containerStatuses: [State]?
        let initContainerStatuses: [State]?
        let ephemeralContainerStatuses: [State]?
    }
    private struct Marker: Decodable {
        private enum CodingKeys: String, CodingKey { case startedAt }
        init(from decoder: any Decoder) throws {
            _ = try decoder.container(keyedBy: CodingKeys.self)
        }
    }
    private struct State: Decodable {
        let name: String
        let state: Value?
        struct Value: Decodable {
            let running: Marker?
            let waiting: Marker?
            let terminated: Marker?
            var value: ContainerState {
                // Ambiguous/malformed states must never enable an exec.
                guard [running != nil, waiting != nil, terminated != nil].filter({ $0 }).count == 1 else { return .unknown }
                if running != nil { return .running }
                return waiting != nil ? .waiting : .terminated
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .apiVersion) == "v1",
              try values.decode(String.self, forKey: .kind) == "Pod" else {
            throw PodDetailsError.malformed
        }
        let metadata = try values.decode(Metadata.self, forKey: .metadata)
        guard [metadata.uid, metadata.name, metadata.namespace].allSatisfy({
            !$0.isEmpty && $0.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        }) else { throw PodDetailsError.malformed }
        uid = metadata.uid
        name = metadata.name
        namespace = metadata.namespace
        defaultContainer = metadata.annotations?.defaultContainer
        let spec = try values.decode(Spec.self, forKey: .spec)
        let status = try values.decodeIfPresent(Status.self, forKey: .status)
        containers = try Self.containers(spec.containers, status?.containerStatuses, kind: .regular)
            + Self.containers(spec.initContainers ?? [], status?.initContainerStatuses, kind: .initContainer)
            + Self.containers(spec.ephemeralContainers ?? [], status?.ephemeralContainerStatuses, kind: .ephemeral)
    }

    private static func containers(_ declarations: [Declaration], _ states: [State]?, kind: ContainerKind) throws -> [Container] {
        let states = states ?? []
        guard Set(declarations.map(\.name)).count == declarations.count,
              Set(states.map(\.name)).count == states.count,
              declarations.allSatisfy({ !$0.name.isEmpty && $0.name.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil })
        else { throw PodDetailsError.malformed }
        let byName = Dictionary(uniqueKeysWithValues: states.map { ($0.name, $0.state?.value ?? .unknown) })
        return declarations.map { Container(name: $0.name, kind: kind, state: byName[$0.name] ?? .unknown) }
    }
}

public enum PodDetailsError: Error, Equatable, Sendable, LocalizedError {
    case malformed, replaced, identityMismatch

    public var errorDescription: String? {
        switch self {
        case .malformed: "The server returned invalid Pod details. Refresh pods and try again."
        case .replaced: "This pod was replaced (UID changed). Refresh pods and select the replacement."
        case .identityMismatch: "Pod details did not match the selected name and namespace. Refresh pods and try again."
        }
    }
}
