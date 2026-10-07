import Foundation
@testable import KubixCore
import Testing

/// A deployments Table as the server prints one, with creation times for the computed Age column.
private func deploymentTable(_ rows: [(name: String, printedAge: String, created: String?)]) throws -> KubernetesTable {
    let encoded = rows.enumerated().map { index, row in
        let created = row.created.map { #","creationTimestamp":"\#($0)""# } ?? ""
        return #"{"cells":["\#(row.name)","3/3","3","3","\#(row.printedAge)"],"object":{"metadata":{"uid":"uid-\#(index)","name":"\#(row.name)","namespace":"team"\#(created)}}}"#
    }.joined(separator: ",")
    return try JSONDecoder().decode(KubernetesTable.self, from: Data("""
    {"apiVersion":"meta.k8s.io/v1","kind":"Table","metadata":{"resourceVersion":"1"},
     "columnDefinitions":[{"name":"Name","type":"string"},{"name":"Ready","type":"string"},
      {"name":"Up-to-date","type":"string"},{"name":"Available","type":"string"},{"name":"Age","type":"string"}],
     "rows":[\(encoded)]}
    """.utf8))
}

private func present(
    _ table: KubernetesTable, connection: ListConnection = .live, filter: String = "",
    sort: ResourceTablePresentation.Sort? = nil, metrics: [String: PodUsage]? = nil
) throws -> ResourceTablePresentation {
    ResourceTablePresentation(
        kind: .deployments, rows: try table.rows.map(ResourceRow.init), columns: table.columnDefinitions,
        connection: connection, filter: filter, sort: sort, metrics: metrics
    )
}

@Suite struct DeploymentTableTests {
    /// Age is the app's column for any kind, because the server prints it once when it builds the
    /// row. Usage is not: it comes from a pod-only API, and offering samples for a deployment must
    /// not conjure columns that cannot be filled.
    @Test func ageIsComputedAndUsageColumnsNeverAppear() throws {
        let table = try deploymentTable([("web", "6d", "2026-10-01T00:00:00Z")])
        let usage = PodUsage(
            name: "web", cpuNanocores: 250_000_000, memoryBytes: 234_881_024,
            timestamp: Date(timeIntervalSince1970: 2_000_000_000), window: 15
        )
        let presentation = try present(table, metrics: ["web": usage])
        #expect(presentation.columns.map(\.definition.name) == ["Name", "Ready", "Up-to-date", "Available", "Age"])
        #expect(presentation.columns.map(\.kind) == [.server, .server, .server, .server, .age])
        #expect(!presentation.columns.contains { $0.kind == .cpu || $0.kind == .memory })
        #expect(presentation.rows.first?.created == RFC3339.date(from: "2026-10-01T00:00:00Z"))
    }

    /// The same defect a computed Age fixed for pods: `2d` and `44h` sort the wrong way round as
    /// text, and the server's printed cell is all a deployments Table carries.
    @Test func ageSortsByCreationTimeRatherThanItsPrintedText() throws {
        let table = try deploymentTable([
            ("older", "2d", "2026-10-01T00:00:00Z"),
            ("newer", "44h", "2026-10-01T04:00:00Z"),
        ])
        let youngestFirst = try present(table, sort: .init(column: 4))
        #expect(youngestFirst.rows.map { $0.cells[0] } == ["newer", "older"])
        let oldestFirst = try present(table, sort: .init(column: 4, ascending: false))
        #expect(oldestFirst.rows.map { $0.cells[0] } == ["older", "newer"])
    }

    @Test func everySentenceNamesDeploymentsRatherThanPods() throws {
        let empty = try present(try deploymentTable([]))
        #expect(empty.state == .empty && empty.message == "Live — no deployments in this namespace.")
        #expect(empty.subtitle == "No deployments")

        let one = try present(try deploymentTable([("web", "6d", nil)]))
        #expect(one.message == "Live — 1 of 1 deployment." && one.subtitle == "1 deployment")

        let two = try present(try deploymentTable([("web", "6d", nil), ("api", "2d", nil)]))
        #expect(two.message == "Live — 2 of 2 deployments." && two.subtitle == "2 deployments")

        let filtered = try present(try deploymentTable([("web", "6d", nil)]), filter: "nothing")
        #expect(filtered.state == .filteredEmpty)
        #expect(filtered.message == "Live — no matches in 1 deployment. Clear the filter to see them.")

        let forbidden = try present(try deploymentTable([]), connection: .failed(.http(code: 403, resource: "deployments")))
        #expect(forbidden.message.hasPrefix("Forbidden: deployments. Check access to this namespace."))

        let idle = try present(try deploymentTable([]), connection: .idle)
        #expect(idle.message == "Choose a context and namespace, then load deployments.")
    }

    /// Search still reads the printed columns and still refuses the live ones, so a filter cannot
    /// match an age that is about to tick past it.
    @Test func searchMatchesPrintedCellsAndNotTheComputedAge() throws {
        let table = try deploymentTable([("web", "6d", "2026-10-01T00:00:00Z"), ("api", "6d", "2026-10-01T00:00:00Z")])
        #expect(try present(table, filter: "web").rows.map { $0.cells[0] } == ["web"])
        #expect(try present(table, filter: "6d").rows.isEmpty)
        #expect(try present(table).columns.map(\.isSearchable) == [true, true, true, true, false])
    }
}
