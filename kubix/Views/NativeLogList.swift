import AppKit
import KubixCore
import SwiftUI

/// NSTableView virtualizes cells on macOS 14. Only the bounded filtered ring is copied for display.
struct NativeLogList: NSViewRepresentable {
    let session: LogSession
    let actions: AppActions

    func makeCoordinator() -> Coordinator { Coordinator(session: session, actions: actions) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.identifier = NSUserInterfaceItemIdentifier("log-lines-\(session.id)")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        column.width = 2_000
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 20
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = table
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.scrolled(_:)),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView
        )
        context.coordinator.update(table)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let table = view.documentView as? NSTableView else { return }
        context.coordinator.update(table)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let session: LogSession
        let actions: AppActions
        private var lines: [LogLine] = []
        private var updating = false
        init(session: LogSession, actions: AppActions) { self.session = session; self.actions = actions }

        func update(_ table: NSTableView) {
            updating = true
            defer { updating = false }
            let next = session.buffer.filtered(session.filter)
            if lines != next {
                let anchor = session.autoscroll ? nil : topAnchor(in: table)
                lines = next
                table.reloadData()
                if !session.autoscroll { restore(anchor, in: table) }
            }
            if session.autoscroll, let last = lines.indices.last,
               table.rect(ofRow: last).maxY > table.visibleRect.maxY {
                table.scrollRowToVisible(last)
            }
        }

        private func topAnchor(in table: NSTableView) -> (id: UInt64, offset: CGFloat)? {
            let row = table.rows(in: table.visibleRect).location
            guard lines.indices.contains(row) else { return nil }
            return (lines[row].id, table.visibleRect.minY - table.rect(ofRow: row).minY)
        }

        private func restore(_ anchor: (id: UInt64, offset: CGFloat)?, in table: NSTableView) {
            guard let scroll = table.enclosingScrollView else { return }
            // reloadData defers document sizing; clamp against the new extent, not the old one.
            scroll.layoutSubtreeIfNeeded()
            let clip = scroll.contentView
            var y: CGFloat = 0
            if !lines.isEmpty {
                if let anchor, let row = lines.firstIndex(where: { $0.id == anchor.id }) {
                    y = table.rect(ofRow: row).minY + anchor.offset
                } else {
                    // Removed by eviction or filtering: start at the oldest visible line, fully shown.
                    y = table.rect(ofRow: 0).minY
                }
            }
            var bounds = clip.bounds
            bounds.origin.y = table.convert(NSPoint(x: 0, y: y), to: clip).y
            // Shorter/empty results cannot retain an offset beyond their scrollable extent.
            let origin = clip.constrainBoundsRect(bounds).origin
            guard origin != clip.bounds.origin else { return }
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
        }

        @objc func scrolled(_ notification: Notification) {
            guard !updating, session.autoscroll, let clip = notification.object as? NSClipView,
                  let document = clip.documentView, document.bounds.height > clip.bounds.height,
                  clip.bounds.maxY < document.bounds.maxY - 4 else { return }
            actions.setLogAutoscroll(session.id, false)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard lines.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("log-line")
            let field = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField ?? NSTextField(labelWithString: "")
            field.identifier = identifier
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            let line = lines[row]
            // The pod's name is drawn in front of its line, as `kubectl` prefixes an aggregated
            // tail, and only when the tab holds more than one stream to tell apart.
            let prefix = line.source.map { "[\($0)] " } ?? ""
            field.stringValue = prefix + line.text
                + (line.truncated ? " [truncated]" : "") + (line.repairedUTF8 ? " [UTF-8 repaired]" : "")
            field.textColor = line.isBoundary ? .secondaryLabelColor : .labelColor
            field.isSelectable = true
            field.lineBreakMode = .byTruncatingTail
            return field
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
