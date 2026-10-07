import Foundation

/// A deployment's identity, the pods it owns, and the containers its template declares. Deliberately
/// not Codable, and deliberately narrow: no raw spec, strategy, environment, arbitrary annotations or
/// status conditions are retained — only what opening logs needs.
public struct DeploymentDetails: Decodable, Equatable, Sendable {
    public let uid: String
    public let name: String
    public let namespace: String
    /// `spec.selector.matchLabels`, which is what finds the deployment's pods. Never empty: a
    /// deployment whose selector matched everything is a selector this cannot safely resolve.
    public let selector: [String: String]
    /// The pod template's `kubectl.kubernetes.io/default-container`, if it names one.
    public let defaultContainer: String?
    /// What the template declares, in the order a pod would report it. These carry `.declared`
    /// state: a template has no single state across replicas, and this never reads one.
    public let containers: [PodDetails.Container]

    private enum CodingKeys: String, CodingKey { case apiVersion, kind, metadata, spec }
    private struct Metadata: Decodable {
        let uid: String
        let name: String
        let namespace: String
    }
    private struct Spec: Decodable {
        let selector: Selector
        let template: Template
    }
    private struct Selector: Decodable {
        let matchLabels: [String: String]?
        let matchExpressions: [Expression]?
    }
    /// Decoded only to be refused: a set-based selector has to be serialized into the label-selector
    /// grammar, and a mistake there silently tails another workload's pods.
    private struct Expression: Decodable {
        private enum CodingKeys: String, CodingKey { case key }
        init(from decoder: any Decoder) throws { _ = try decoder.container(keyedBy: CodingKeys.self) }
    }
    private struct Template: Decodable {
        let metadata: TemplateMetadata?
        let spec: TemplateSpec
    }
    private struct TemplateMetadata: Decodable {
        let annotations: Annotation?
    }
    private struct Annotation: Decodable {
        let defaultContainer: String?
        enum CodingKeys: String, CodingKey { case defaultContainer = "kubectl.kubernetes.io/default-container" }
    }
    private struct TemplateSpec: Decodable {
        let containers: [Declaration]
        let initContainers: [Declaration]?
    }
    private struct Declaration: Decodable {
        let name: String
        let restartPolicy: String?
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .apiVersion) == "apps/v1",
              try values.decode(String.self, forKey: .kind) == "Deployment" else {
            throw DeploymentDetailsError.malformed
        }
        let metadata = try values.decode(Metadata.self, forKey: .metadata)
        guard [metadata.uid, metadata.name, metadata.namespace].allSatisfy({
            !$0.isEmpty && $0.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        }) else { throw DeploymentDetailsError.malformed }
        uid = metadata.uid
        name = metadata.name
        namespace = metadata.namespace
        let spec = try values.decode(Spec.self, forKey: .spec)
        guard spec.selector.matchExpressions?.isEmpty ?? true else { throw DeploymentDetailsError.setBasedSelector }
        let labels = spec.selector.matchLabels ?? [:]
        guard !labels.isEmpty else { throw DeploymentDetailsError.emptySelector }
        selector = labels
        defaultContainer = spec.template.metadata?.annotations?.defaultContainer
        containers = try Self.containers(spec.template.spec.containers, kind: .regular)
            + Self.containers(spec.template.spec.initContainers ?? [], kind: .initContainer)
    }

    private static func containers(_ declarations: [Declaration], kind: PodDetails.ContainerKind) throws -> [PodDetails.Container] {
        guard Set(declarations.map(\.name)).count == declarations.count,
              declarations.allSatisfy({
                  !$0.name.isEmpty && $0.name.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
              }) else { throw DeploymentDetailsError.malformed }
        return declarations.map {
            PodDetails.Container(
                name: $0.name, kind: kind, state: .declared,
                isSidecar: kind == .initContainer && $0.restartPolicy == "Always"
            )
        }
    }
}

public enum DeploymentDetailsError: Error, Equatable, Sendable, LocalizedError {
    case malformed, replaced, identityMismatch, emptySelector, setBasedSelector, noContainers

    public var errorDescription: String? {
        switch self {
        case .malformed: "The server returned invalid Deployment details. Refresh and try again."
        case .replaced: "This deployment was replaced (UID changed). Refresh and select the replacement."
        case .identityMismatch: "Deployment details did not match the selected name and namespace. Refresh and try again."
        case .emptySelector: "This deployment has no pod selector, so its pods cannot be identified."
        case .setBasedSelector:
            "This deployment selects its pods with matchExpressions, which Kubix does not resolve yet. "
                + "Open logs on its pods from the Pods list instead."
        case .noContainers: "This deployment's pod template declares no containers."
        }
    }
}
