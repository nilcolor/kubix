import Foundation

/// A namespaced resource the app lists. One watch serves whichever kind is selected, so everything
/// that differs between them is a property here rather than a branch at the call site.
///
/// Pods and deployments are read the same way — a paginated server-side Table, then a watch — and
/// differ only in what the list can do with a row: a shell needs a container to exec into, and the
/// usage columns come from `metrics.k8s.io`, which is per pod and has no deployment equivalent.
public enum ResourceKind: String, Hashable, Sendable, CaseIterable {
    case pods, deployments

    /// The API prefix the resource lives under. `APIRequest` composes this with the namespace.
    public var apiPath: [String] {
        switch self {
        case .pods: ["api", "v1"]
        case .deployments: ["apis", "apps", "v1"]
        }
    }

    /// The URL segment, which is also the plural the server knows the resource by.
    public var resource: String { rawValue }

    public var title: String {
        switch self {
        case .pods: "Pods"
        case .deployments: "Deployments"
        }
    }

    /// What a count is counting, for subtitles and status sentences.
    public var noun: (one: String, many: String) {
        switch self {
        case .pods: ("pod", "pods")
        case .deployments: ("deployment", "deployments")
        }
    }

    public var symbol: String {
        switch self {
        case .pods: "shippingbox"
        case .deployments: "square.stack.3d.up"
        }
    }

    /// Only a pod has containers to exec into. A deployment's shell would have to pick a replica,
    /// which is a different action than the one the button offers.
    public var supportsShell: Bool { self == .pods }

    /// `metrics.k8s.io` reports per pod and has no deployment resource. Summing a deployment's pods
    /// means walking pods → ReplicaSets → Deployment ownerReferences, which this does not do.
    public var supportsUsageColumns: Bool { self == .pods }
}
