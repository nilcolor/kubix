import Foundation

/// What the dashboard knows about one section. `notPermitted` and `tooLarge` are answers, not
/// failures: neither changes by asking again, so neither is asked again until the next Connect.
public enum OverviewValue<Value: Equatable & Sendable>: Equatable, Sendable {
    case unknown
    case value(Value)
    case notPermitted
    case tooLarge
    /// Never answered, or its last answer is too old to describe now.
    case failed

    public var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }

    /// Whether the next poll should ask for this section at all.
    public var isSettled: Bool { self == .notPermitted || self == .tooLarge }
}

public enum OverviewSection: Hashable, Sendable {
    case nodes, warningEvents
    case workload(WorkloadKind)

    public static let all: [OverviewSection] = [.nodes, .warningEvents] + WorkloadKind.allCases.map(Self.workload)
}

/// Cluster-wide counts behind the dashboard, kept per cluster so returning to it shows the last
/// numbers while a fresh poll runs.
public struct ClusterOverview: Equatable, Sendable {
    public var nodes: OverviewValue<NodeCounts> = .unknown
    public var warningEvents: OverviewValue<Int> = .unknown
    public var workloads: [WorkloadKind: OverviewValue<WorkloadCounts>] = [:]

    public init() {}

    public func workload(_ kind: WorkloadKind) -> OverviewValue<WorkloadCounts> { workloads[kind] ?? .unknown }

    public func isSettled(_ section: OverviewSection) -> Bool {
        switch section {
        case .nodes: nodes.isSettled
        case .warningEvents: warningEvents.isSettled
        case .workload(let kind): workload(kind).isSettled
        }
    }

    public func hasValue(_ section: OverviewSection) -> Bool {
        switch section {
        case .nodes: nodes.value != nil
        case .warningEvents: warningEvents.value != nil
        case .workload(let kind): workload(kind).value != nil
        }
    }

    /// Sets a section to a non-value state.
    public mutating func mark(_ section: OverviewSection, _ state: OverviewState) {
        switch section {
        case .nodes: nodes = state.value()
        case .warningEvents: warningEvents = state.value()
        case .workload(let kind): workloads[kind] = state.value()
        }
    }
}

public enum OverviewState: Sendable {
    case notPermitted, tooLarge, failed

    func value<Value>() -> OverviewValue<Value> {
        switch self {
        case .notPermitted: .notPermitted
        case .tooLarge: .tooLarge
        case .failed: .failed
        }
    }
}
