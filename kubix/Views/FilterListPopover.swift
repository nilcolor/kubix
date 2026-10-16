import AppKit
import KubixCore

/// What a pop-up menu does — show the choices, mark the current one, take one — plus a filter field,
/// which an `NSMenu` cannot host reliably: a text field inside a menu's tracking loop loses keys and
/// cannot hide items without fighting the menu's own layout. The field keeps key focus throughout and
/// drives the list from the field editor's commands, so typing, arrows, Return and Escape all work
/// without the table ever taking focus.
@MainActor final class FilterListController: NSViewController, NSSearchFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    private static let rowHeight: CGFloat = 24
    private static let visibleRows = 12
    private static let width: CGFloat = 260

    /// A set although the namespace picker only ever marks one: every row draws its own checkmark, so
    /// choosing several namespaces later changes what `choose` does, not how the list is drawn.
    var selected: Set<String> = [] { didSet { if selected != oldValue { table.reloadData() } } }
    var items: [String] = [] { didSet { if items != oldValue { applyFilter() } } }

    private let choose: (String) -> Void
    private let dismiss: () -> Void
    private let field = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty: NSTextField
    private var shown: [String] = []
    private var listHeight: NSLayoutConstraint?

    init(
        placeholder: String, emptyText: String, identifier: String,
        choose: @escaping (String) -> Void, dismiss: @escaping () -> Void
    ) {
        self.choose = choose
        self.dismiss = dismiss
        empty = NSTextField(labelWithString: emptyText)
        super.init(nibName: nil, bundle: nil)
        field.placeholderString = placeholder
        table.identifier = NSUserInterfaceItemIdentifier(identifier)
        table.setAccessibilityIdentifier(identifier)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        // The field owns focus; a focused table would take the arrows and Return away from it.
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(field)
        root.addSubview(scroll)
        root.addSubview(empty)
        let height = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        listHeight = height
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            height,
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        view = root
    }

    /// Every opening starts from the whole list with the current choice highlighted, the way a pop-up
    /// menu opens on its selected item. The height is fixed per opening so the popover does not jump
    /// while the user types.
    func prepareForOpening() {
        loadViewIfNeeded()
        field.stringValue = ""
        listHeight?.constant = CGFloat(min(max(items.count, 1), Self.visibleRows)) * Self.rowHeight
        applyFilter()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    private func applyFilter() {
        guard isViewLoaded else { return }
        shown = NamespaceSelection.matching(items, filter: field.stringValue)
        table.reloadData()
        empty.isHidden = !shown.isEmpty
        let current = field.stringValue.isEmpty ? shown.firstIndex(where: selected.contains) : nil
        highlight(current ?? (shown.isEmpty ? nil : 0))
    }

    private func highlight(_ row: Int?) {
        guard let row else { table.deselectAll(nil); return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func move(by offset: Int) {
        guard !shown.isEmpty else { return }
        let next = table.selectedRow < 0 ? 0 : table.selectedRow + offset
        highlight(min(max(next, 0), shown.count - 1))
    }

    @objc private func clicked(_ sender: NSTableView) {
        guard shown.indices.contains(sender.clickedRow) else { return }
        choose(shown[sender.clickedRow])
    }

    func controlTextDidChange(_ notification: Notification) { applyFilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            if shown.indices.contains(table.selectedRow) { choose(shown[table.selectedRow]) }
        // The first Escape clears a filter, as a search field does; on an empty one it closes the list.
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { dismiss() } else { field.stringValue = ""; applyFilter() }
        default: return false
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { HighlightRow() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ChoiceCell.reuse, owner: nil) as? ChoiceCell ?? ChoiceCell()
        cell.show(shown[row], checked: selected.contains(shown[row]))
        return cell
    }
}

/// The highlighted row is the keyboard cursor, and the table never holds focus, so AppKit would draw
/// it in the inactive grey; a menu's highlight is always the accent colour.
private final class HighlightRow: NSTableRowView {
    override var isEmphasized: Bool { get { true } set { _ = newValue } }
}

private final class ChoiceCell: NSTableCellView {
    static let reuse = NSUserInterfaceItemIdentifier("filter-list-choice")
    private let check = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuse
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Selected")
        check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        for view in [check, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = check
        textField = label
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ name: String, checked: Bool) {
        label.stringValue = name
        check.isHidden = !checked
        setAccessibilityLabel(checked ? "\(name), selected" : name)
    }
}
