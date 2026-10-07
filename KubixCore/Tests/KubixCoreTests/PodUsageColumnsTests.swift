import Foundation
@testable import KubixCore
import Testing

/// A pod Table the way the server prints it, with names and creation times, for the columns the app
/// computes on top of it.
func usageTable(_ pods: [(name: String, printedAge: String, created: String?)]) throws -> KubernetesTable {
    let rows = pods.enumerated().map { index, pod in
        let created = pod.created.map { #","creationTimestamp":"\#($0)""# } ?? ""
        return #"{"cells":["\#(pod.name)","Running","\#(pod.printedAge)"],"object":{"metadata":{"uid":"uid-\#(index)","name":"\#(pod.name)","namespace":"team"\#(created)}}}"#
    }.joined(separator: ",")
    return try JSONDecoder().decode(KubernetesTable.self, from: Data("""
    {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"1"},
     "columnDefinitions":[{"name":"Name","type":"string"},{"name":"Status","type":"string"},{"name":"Age","type":"string"}],
     "rows":[\(rows)]}
    """.utf8))
}

private func present(
    _ table: KubernetesTable, filter: String = "", sort: ResourceTablePresentation.Sort? = nil,
    metrics: [String: PodUsage]? = nil
) throws -> ResourceTablePresentation {
    ResourceTablePresentation(
        rows: try table.rows.map(ResourceRow.init), columns: table.columnDefinitions, connection: .live,
        filter: filter, sort: sort, metrics: metrics
    )
}

/// Well after every fixture pod's creation, so a default sample is one those pods could have produced.
private let taken = Date(timeIntervalSince1970: 2_000_000_000)

private func sample(_ name: String, cpu: Decimal, memory: Decimal, windowStart: Date? = nil) -> PodUsage {
    let start = windowStart ?? taken.addingTimeInterval(-15)
    return PodUsage(name: name, cpuNanocores: cpu, memoryBytes: memory, timestamp: taken, window: taken.timeIntervalSince(start))
}

@Suite struct PodUsageColumnsTests {
    /// The server prints `2d` for the older pod and `44h` for the newer; as text those sort the wrong
    /// way round, which is the defect a computed Age removes.
    @Test func ageSortsByCreationTimeRatherThanItsPrintedText() throws {
        let table = try usageTable([
            ("older", "2d", "2026-09-10T00:00:00Z"),
            ("newer", "44h", "2026-09-11T00:00:00Z"),
            ("newest", "5m", "2026-09-12T23:00:00Z"),
        ])
        let age = try #require(try present(table).columns.first { $0.kind == .age })
        let ascending = try present(table, sort: .init(column: age.id, ascending: true))
        #expect(ascending.rows.map(\.cells.first) == ["newest", "newer", "older"])
        let descending = try present(table, sort: .init(column: age.id, ascending: false))
        #expect(descending.rows.map(\.cells.first) == ["older", "newer", "newest"])
        #expect(ascending.rows.first?.created == RFC3339.date(from: "2026-09-12T23:00:00Z"))
    }

    @Test func aRowWithoutACreationTimeKeepsThePrintedAge() throws {
        let presentation = try present(try usageTable([("bare", "7h", nil)]))
        #expect(presentation.rows.first?.created == nil)
        #expect(presentation.rows.first?.cells.last == "7h")
    }

    /// A filter that matched `5m` a minute ago would stop matching as the age ticked past it.
    @Test func liveColumnsAreNotSearchKeys() throws {
        let table = try usageTable([("web", "5m", "2026-09-12T23:00:00Z")])
        let usage = ["web": sample("web", cpu: 12_000_000, memory: 134_217_728)]
        #expect(try present(table, filter: "5m", metrics: usage).state == .filteredEmpty)
        #expect(try present(table, filter: "12m", metrics: usage).state == .filteredEmpty)
        #expect(try present(table, filter: "web", metrics: usage).rows.count == 1)
    }

    /// Columns follow the cluster: no metrics API, no usage columns — rather than a column of blanks.
    @Test func usageColumnsSitBeforeAgeOnlyWhenTheClusterServesMetrics() throws {
        let table = try usageTable([("web", "5m", "2026-09-12T23:00:00Z")])
        #expect(try present(table).columns.map(\.definition.name) == ["Name", "Status", "Age"])
        let waiting = try present(table, metrics: [:])
        #expect(waiting.columns.map(\.definition.name) == ["Name", "Status", "CPU", "Memory", "Age"])
        #expect(waiting.rows.first?.cells == ["web", "Running", ResourceTablePresentation.absent, ResourceTablePresentation.absent, "5m"])
    }

    @Test func usageColumnsAppendWhenTheServerPrintsNoAge() throws {
        let table = try presentationTable(cells: [#"["alpha"]"#])
        let presentation = ResourceTablePresentation(
            rows: try table.rows.map(ResourceRow.init), columns: table.columnDefinitions, connection: .live, metrics: [:]
        )
        #expect(presentation.columns.map(\.definition.name) == ["Arbitrary", "CPU", "Memory"])
    }

    /// Displayed as kubectl top prints it, sorted by the exact value, and a pod with no sample sorts
    /// last whichever way the column is sorted.
    @Test func usageReadsAsKubectlTopAndSortsByExactValueWithBlanksLast() throws {
        let table = try usageTable([
            ("small", "1h", "2026-09-12T20:00:00Z"),
            ("pending", "1m", "2026-09-12T23:00:00Z"),
            ("large", "2h", "2026-09-12T19:00:00Z"),
            ("fraction", "3h", "2026-09-12T18:00:00Z"),
        ])
        let usage = [
            "small": sample("small", cpu: 1_000_000, memory: 1_048_576),
            "large": sample("large", cpu: 250_400_000, memory: 536_870_912),
            // Rounds up to the same 2m as a whole 2m would, but is less, and sorts that way.
            "fraction": sample("fraction", cpu: 1_200_000, memory: 2_097_151),
        ]
        let cpu = ResourceTablePresentation.Column.cpu.id
        let ascending = try present(table, sort: .init(column: cpu, ascending: true), metrics: usage)
        #expect(ascending.rows.map(\.cells.first) == ["small", "fraction", "large", "pending"])
        #expect(ascending.rows.map { $0.cells[2] } == ["1m", "2m", "251m", ResourceTablePresentation.absent])
        #expect(ascending.rows.map { $0.cells[3] } == ["1Mi", "1Mi", "512Mi", ResourceTablePresentation.absent])
        let descending = try present(table, sort: .init(column: cpu, ascending: false), metrics: usage)
        #expect(descending.rows.map(\.cells.first) == ["large", "fraction", "small", "pending"])
    }

    /// The metrics API names a pod but has no UID. A replica recreated under the same name must not
    /// show its predecessor's numbers: a sample whose window opened before this pod existed is not its.
    @Test func aSampleFromBeforeThePodExistedIsNotItsUsage() throws {
        let created = try #require(RFC3339.date(from: "2026-09-12T23:00:00Z"))
        let table = try usageTable([("web-0", "30s", "2026-09-12T23:00:00Z")])
        let predecessor = sample("web-0", cpu: 5_000_000, memory: 1_048_576, windowStart: created.addingTimeInterval(-30))
        #expect(try present(table, metrics: ["web-0": predecessor]).rows.first?.cells[2] == ResourceTablePresentation.absent)
        // Whole-second timestamps: a window opening in the same second as the pod is still its own.
        let own = sample("web-0", cpu: 5_000_000, memory: 1_048_576, windowStart: created.addingTimeInterval(-0.5))
        #expect(try present(table, metrics: ["web-0": own]).rows.first?.cells[2] == "5m")
    }
}
