import KubixCore
import SwiftUI

/// Cluster-wide counts per workload kind. A column that means nothing for a kind — a Deployment
/// never succeeds — is a dash, not a zero.
struct WorkloadSummary: View {
    let overview: ClusterOverview
    private let columns = ["Total", "Running", "Succeeded", "Pending", "Failed"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Workloads").font(.title3.weight(.semibold))
                .padding(.bottom, 10)

            HStack(spacing: 12) {
                Text("Resource").font(.callout).foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)
                Spacer(minLength: 0)
                ForEach(columns, id: \.self) { column in
                    Text(column).font(.callout).foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .trailing)
                }
            }
            .padding(.bottom, 6)

            ForEach(WorkloadKind.allCases, id: \.self) { kind in
                Divider()
                WorkloadRow(title: kind.title, reading: overview.workload(kind))
            }
            Divider()
        }
    }
}

private struct WorkloadRow: View {
    let title: String
    let reading: OverviewValue<WorkloadCounts>

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).fontWeight(.medium)
                if let problem = reading.problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                } else {
                    ProportionBar(counts: reading.value)
                }
            }
            .frame(width: 130, alignment: .leading)
            Spacer(minLength: 0)
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                HStack {
                    Spacer(minLength: 0)
                    if let cell {
                        Text(cell).monospacedDigit().foregroundStyle(cell == "—" ? .secondary : .primary)
                    } else {
                        Skeleton(width: index == 0 ? 34 : 26, height: 10, shade: 0.12)
                    }
                }
                .frame(width: 76)
            }
        }
        .padding(.vertical, 10)
    }

    /// nil is a cell not yet known, drawn as a skeleton.
    private var cells: [String?] {
        guard let counts = reading.value else {
            return Array(repeating: reading == .unknown ? nil : "—", count: 5)
        }
        return [counts.total, counts.running, counts.succeeded, counts.pending, counts.failed].map { $0.map(String.init) ?? "—" }
    }
}

/// How each kind's objects split across the columns. Anything outside them — an idle CronJob, a pod
/// in phase Unknown — is the grey remainder.
private struct ProportionBar: View {
    let counts: WorkloadCounts?
    private let width: CGFloat = 150

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                Rectangle().fill(segment.color).frame(width: width * segment.fraction, height: 4)
            }
        }
        .frame(width: width, height: 4, alignment: .leading)
        .background(Color.secondary.opacity(0.12))
        .clipShape(Capsule())
    }

    private var segments: [(fraction: CGFloat, color: Color)] {
        guard let counts, counts.total > 0 else { return [] }
        let parts: [(Int?, Color)] = [
            (counts.running, .green), (counts.succeeded, .blue), (counts.pending, .orange), (counts.failed, .red),
        ]
        return parts.compactMap { value, color in
            guard let value, value > 0 else { return nil }
            return (CGFloat(value) / CGFloat(counts.total), color)
        }
    }
}

extension OverviewValue {
    /// Why there is no number, in the words the pane shows.
    var problem: String? {
        switch self {
        case .unknown, .value: nil
        case .notPermitted: "Listing not permitted"
        case .tooLarge: "Too many to count"
        case .failed: "Couldn’t load"
        }
    }
}
