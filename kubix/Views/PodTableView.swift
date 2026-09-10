import KubixCore
import SwiftUI

struct PodTableView: View {
    let store: AppStore
    let actions: AppActions

    var body: some View {
        let presentation = store.podTable
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pods").font(.headline)
                TextField("Filter visible columns", text: Binding(get: { store.podFilter }, set: { actions.setPodFilter($0) }))
                    .accessibilityIdentifier("pod-filter")
                if !store.podFilter.isEmpty { Button("Clear") { actions.setPodFilter("") } }
                Toggle("Wide", isOn: Binding(get: { store.podWide }, set: { actions.setPodWide($0) }))
                    .toggleStyle(.checkbox)
                    .help("Show all server columns, including priority columns")
            }
            HStack(alignment: .top) {
                if presentation.state == .connecting { ProgressView().controlSize(.small) }
                Text(presentation.message)
                    .foregroundStyle(presentation.state == .failed ? Color.orange : Color.secondary)
                    .font(.caption).textSelection(.enabled)
                Spacer(minLength: 0)
                if presentation.state == .failed { Button("Retry pods") { actions.refreshPods() } }
            }
            NativePodTable(presentation: presentation, actions: actions)
        }
        .padding(8)
    }
}

/// NSTableView supports runtime-defined columns on macOS 14, including repeated server labels.
struct NativePodTable: NSViewRepresentable {
    let presentation: PodTablePresentation
    let actions: AppActions

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.identifier = NSUserInterfaceItemIdentifier("pod-table")
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.rowHeight = 24
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
            let field = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
                ?? NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
            field.stringValue = presentation.rows[row].cells[column]
            field.toolTip = field.stringValue
            return field
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
