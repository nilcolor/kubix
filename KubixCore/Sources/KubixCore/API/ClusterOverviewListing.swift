import Foundation

/// A row of the dashboard's workload table. Deliberately not `ResourceKind`: that type is what the
/// sidebar can list and watch, and these are only ever counted.
public enum WorkloadKind: String, Hashable, Sendable, CaseIterable {
    case pods, deployments, daemonSets, statefulSets, jobs, cronJobs

    public var apiPath: [String] {
        switch self {
        case .pods: ["api", "v1"]
        case .deployments, .daemonSets, .statefulSets: ["apis", "apps", "v1"]
        case .jobs, .cronJobs: ["apis", "batch", "v1"]
        }
    }

    public var resource: String { rawValue.lowercased() }

    public var title: String {
        switch self {
        case .pods: "Pods"
        case .deployments: "Deployments"
        case .daemonSets: "DaemonSets"
        case .statefulSets: "StatefulSets"
        case .jobs: "Jobs"
        case .cronJobs: "CronJobs"
        }
    }
}

/// Cluster-wide counts for the dashboard. The API has no aggregate endpoint and nothing here is
/// watched: each call is a complete paginated list, reduced to numbers as it arrives.
public protocol ClusterOverviewListing: Sendable {
    func nodes(context: ResolvedContext) async throws -> NodeCounts
    func warningEvents(context: ResolvedContext) async throws -> Int
    func workloads(_ kind: WorkloadKind, context: ResolvedContext) async throws -> WorkloadCounts
}

public enum ClusterOverviewFailure: String, Error, Equatable, Sendable {
    case malformed
    /// A count over a truncated list is a wrong number, so exceeding a budget throws instead.
    case tooManyPages
    case tooManyBytes
}

public struct NodeCounts: Equatable, Sendable {
    public var total: Int
    public var ready: Int

    public init(total: Int = 0, ready: Int = 0) {
        self.total = total
        self.ready = ready
    }

    public mutating func add(_ node: NodeObject) {
        total += 1
        if node.isReady { ready += 1 }
    }
}

/// One row of the workload table. A nil column is one that has no meaning for the kind — a
/// Deployment never "succeeds" — and is shown as a dash rather than a zero.
public struct WorkloadCounts: Equatable, Sendable {
    public var total: Int
    public var running: Int
    public var succeeded: Int?
    public var pending: Int?
    public var failed: Int?

    public init(total: Int = 0, running: Int = 0, succeeded: Int? = nil, pending: Int? = nil, failed: Int? = nil) {
        self.total = total
        self.running = running
        self.succeeded = succeeded
        self.pending = pending
        self.failed = failed
    }

    /// The columns each kind has, all zero.
    public static func empty(_ kind: WorkloadKind) -> WorkloadCounts {
        switch kind {
        case .pods, .jobs: WorkloadCounts(succeeded: 0, pending: 0, failed: 0)
        case .deployments: WorkloadCounts(pending: 0, failed: 0)
        case .daemonSets, .statefulSets, .cronJobs: WorkloadCounts(pending: 0)
        }
    }

    public static func tally(_ kind: WorkloadKind, _ objects: [WorkloadObject]) -> WorkloadCounts {
        var counts = empty(kind)
        for object in objects { counts.add(object, as: kind) }
        return counts
    }

    public mutating func add(_ object: WorkloadObject, as kind: WorkloadKind) {
        total += 1
        switch object.state(as: kind) {
        case .running: running += 1
        case .succeeded: succeeded = (succeeded ?? 0) + 1
        case .pending: pending = (pending ?? 0) + 1
        case .failed: failed = (failed ?? 0) + 1
        case .other: break
        }
    }
}

/// The few `spec`/`status` fields the workload kinds are counted from. Every field is optional so one
/// type decodes all five kinds, and a field a kind lacks is simply absent.
public struct WorkloadObject: Decodable, Equatable, Sendable {
    public struct Spec: Decodable, Equatable, Sendable {
        public var replicas: Int?
        public var suspend: Bool?

        public init(replicas: Int? = nil, suspend: Bool? = nil) {
            self.replicas = replicas
            self.suspend = suspend
        }
    }

    public struct Status: Decodable, Equatable, Sendable {
        public var readyReplicas: Int?
        public var desiredNumberScheduled: Int?
        public var numberReady: Int?
        /// A Job reports a number of active pods, a CronJob a list of its running Jobs; both read as
        /// "how many are running now".
        public var active: Int?
        public var conditions: [Condition]?

        enum CodingKeys: String, CodingKey { case readyReplicas, desiredNumberScheduled, numberReady, active, conditions }

        public init(
            readyReplicas: Int? = nil, desiredNumberScheduled: Int? = nil, numberReady: Int? = nil,
            active: Int? = nil, conditions: [Condition]? = nil
        ) {
            self.readyReplicas = readyReplicas
            self.desiredNumberScheduled = desiredNumberScheduled
            self.numberReady = numberReady
            self.active = active
            self.conditions = conditions
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            readyReplicas = try values.decodeIfPresent(Int.self, forKey: .readyReplicas)
            desiredNumberScheduled = try values.decodeIfPresent(Int.self, forKey: .desiredNumberScheduled)
            numberReady = try values.decodeIfPresent(Int.self, forKey: .numberReady)
            conditions = try values.decodeIfPresent([Condition].self, forKey: .conditions)
            if let count = try? values.decodeIfPresent(Int.self, forKey: .active) {
                active = count
            } else {
                active = try values.decodeIfPresent([Ignored].self, forKey: .active)?.count
            }
        }

        private struct Ignored: Decodable {}
    }

    public struct Condition: Decodable, Equatable, Sendable {
        public var type: String
        public var status: String
        public var reason: String?

        public init(type: String, status: String, reason: String? = nil) {
            self.type = type
            self.status = status
            self.reason = reason
        }
    }

    public enum State: Equatable, Sendable { case running, succeeded, pending, failed, other }

    public var spec: Spec?
    public var status: Status?

    public init(spec: Spec? = nil, status: Status? = nil) {
        self.spec = spec
        self.status = status
    }

    public func state(as kind: WorkloadKind) -> State {
        let status = status ?? Status()
        switch kind {
        case .pods:
            return .other
        case .deployments:
            // Only a deadline the controller itself gave up on is a failure; a slow rollout is pending.
            if condition("Progressing")?.status == "False", condition("Progressing")?.reason == "ProgressDeadlineExceeded" {
                return .failed
            }
            return (status.readyReplicas ?? 0) >= (spec?.replicas ?? 1) ? .running : .pending
        case .statefulSets:
            return (status.readyReplicas ?? 0) >= (spec?.replicas ?? 1) ? .running : .pending
        case .daemonSets:
            return (status.numberReady ?? 0) >= (status.desiredNumberScheduled ?? 0) ? .running : .pending
        case .jobs:
            // FailureTarget and SuccessCriteriaMet are set before the final condition, once the
            // outcome is decided and only pod cleanup remains.
            if isTrue("Failed") || isTrue("FailureTarget") { return .failed }
            if isTrue("Complete") || isTrue("SuccessCriteriaMet") { return .succeeded }
            return (status.active ?? 0) > 0 ? .running : .pending
        case .cronJobs:
            if (status.active ?? 0) > 0 { return .running }
            return spec?.suspend == true ? .pending : .other
        }
    }

    private func condition(_ type: String) -> Condition? { status?.conditions?.first { $0.type == type } }
    private func isTrue(_ type: String) -> Bool { condition(type)?.status == "True" }
}

public struct NodeObject: Decodable, Equatable, Sendable {
    public struct Status: Decodable, Equatable, Sendable {
        public var conditions: [WorkloadObject.Condition]?
    }

    public var status: Status?

    public init(conditions: [WorkloadObject.Condition]?) { status = Status(conditions: conditions) }

    /// A node that has not reported a Ready condition is not ready, as `kubectl get nodes` reads it.
    public var isReady: Bool { status?.conditions?.first { $0.type == "Ready" }?.status == "True" }
}
