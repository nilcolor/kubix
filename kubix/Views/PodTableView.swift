import KubixCore
import SwiftUI

struct PodTableView: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        let presentation = store.podTable
        VStack(alignment: .leading, spacing: 6) {
            if store.isLoadingPodDetails {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading fresh Pod details…").font(.caption)
                }
                .padding(.horizontal, textInset)
            }
            if let diagnostic = store.podShellDiagnostic {
                Text(diagnostic).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .padding(.horizontal, textInset)
            }
            if let diagnostic = store.podLogDiagnostic {
                Text(diagnostic).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            // The state's own sentence goes over the table, not above it: a line that appears and
            // disappears as a watch settles moved every row underneath it each time.
            NativePodTable(presentation: presentation, actions: actions)
                .overlay { TableState(presentation: presentation, actions: actions) }
        }
    }

    /// Everything except the table carries the pane's inset; the table bleeds to the edge and insets
    /// its own cells, so one leading edge runs down the whole pane.
    private var textInset: CGFloat { PodsPane.inset }
}

/// What the table is doing, when the rows cannot say it themselves. An empty table has the room for
/// a sentence, and a table with rows already has them to read — so a settling watch says nothing here
/// and leaves the toolbar's spinner and subtitle to report it.
private struct TableState: View {
    let presentation: PodTablePresentation
    let actions: AppActions

    var body: some View {
        if presentation.rows.isEmpty, presentation.state != .idle {
            VStack(spacing: 10) {
                if presentation.state == .connecting || presentation.state == .listed {
                    ProgressView().controlSize(.small)
                }
                Text(presentation.message)
                    .font(.callout)
                    .foregroundStyle(presentation.state == .failed ? Color.orange : .secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420)
                if presentation.state == .failed {
                    Button("Retry pods") { actions.refreshPods() }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            // The header row stays readable and clickable behind this.
            .allowsHitTesting(presentation.state == .failed)
        }
    }
}

/// Centres its label vertically: an `NSTextField` returned straight to the table is stretched to the
/// row and draws its single line against the top edge, which is what made the rows look top-heavy.
final class PodCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            // 2pt restores the bearing a bare NSTextField cell had, so the column keeps the x the
            // pane's inset is matched to.
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not decoded") }
}

/// NSTableView supports runtime-defined columns on macOS 14, including repeated server labels.
struct NativePodTable: NSViewRepresentable {
    let presentation: PodTablePresentation
    let actions: AppActions

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = PodNativeTable()
        table.openShell = { [weak coordinator = context.coordinator] row, menu in
            coordinator?.shellAction(row: row, menu: menu)
        }
        table.openLogs = { [weak coordinator = context.coordinator] row in coordinator?.logsAction(row: row) }
        table.identifier = NSUserInterfaceItemIdentifier("pod-table")
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        // Hairlines rather than alternating bands: a separator per row reads as a list, and stripes
        // fight the inset selection shape.
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = .separatorColor
        table.columnAutoresizingStyle = .noColumnAutoresizing
        // A bare text field stretched to the row draws its text at the top; the cell view centres it,
        // and a row with room to breathe is easier to scan than one sized to the glyphs.
        table.rowHeight = 38
        // Explicit, not .automatic: the row inset is what the pane's own inset has to match.
        table.style = .inset
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        context.coordinator.update(table, presentation: presentation)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let table = view.documentView as? NSTableView else { return }
        context.coordinator.update(table, presentation: presentation)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let actions: AppActions
        private var presentation: PodTablePresentation?
        private var updating = false

        init(actions: AppActions) { self.actions = actions }

        func shellAction(row: Int, menu: Bool) -> (@MainActor () -> Void)? {
            guard let presentation, presentation.rows.indices.contains(row) else { return nil }
            let uid = presentation.rows[row].id
            if menu { return actions.podShellMenuAction(uid: uid) }
            return { [actions] in actions.openPodShell(uid: uid) }
        }

        func logsAction(row: Int) -> (@MainActor () -> Void)? {
            guard let presentation, presentation.rows.indices.contains(row) else { return nil }
            return actions.podLogsMenuAction(uid: presentation.rows[row].id)
        }

        func update(_ table: NSTableView, presentation next: PodTablePresentation) {
            guard presentation != next else { return }
            updating = true
            defer { updating = false }
            let columnsChanged = presentation?.columns != next.columns
            if columnsChanged {
                for column in table.tableColumns { table.removeTableColumn(column) }
                for column in next.columns {
                    let native = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(column.id)))
                    native.title = column.definition.name
                    native.headerToolTip = column.definition.description
                    native.minWidth = 60
                    native.width = min(260, max(110, CGFloat(column.definition.name.count * 9 + 24)))
                    native.sortDescriptorPrototype = NSSortDescriptor(key: String(column.id), ascending: true)
                    table.addTableColumn(native)
                }
            }
            let rowsChanged = presentation?.rows != next.rows
            presentation = next
            let descriptors = next.sort.map { [NSSortDescriptor(key: String($0.column), ascending: $0.ascending)] } ?? []
            if table.sortDescriptors != descriptors { table.sortDescriptors = descriptors }
            if rowsChanged || columnsChanged { table.reloadData() }
            let selected = next.rows.firstIndex { $0.id == next.selectedUID }
            table.selectRowIndexes(selected.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { presentation?.rows.count ?? 0 }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let presentation, let tableColumn,
                  let column = presentation.columns.firstIndex(where: { String($0.id) == tableColumn.identifier.rawValue }),
                  presentation.rows.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("pod-cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? PodCellView ?? PodCellView()
            cell.identifier = identifier
            cell.textField?.stringValue = presentation.rows[row].cells[column]
            cell.toolTip = cell.textField?.stringValue
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView, let presentation else { return }
            actions.selectPod(uid: presentation.rows.indices.contains(table.selectedRow) ? presentation.rows[table.selectedRow].id : nil)
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating else { return }
            let sort = tableView.sortDescriptors.first.flatMap { descriptor in
                descriptor.key.flatMap(Int.init).map { PodTablePresentation.Sort(column: $0, ascending: descriptor.ascending) }
            }
            actions.sortPods(sort)
        }
    }
}
