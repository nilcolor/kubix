#if DEBUG
import AppKit
import KubixCore

/// Sidebar column geometry: it must hold its width across a window resize, honour its bounds, and
/// never let its rows grow wider than the column — a SwiftUI List is a scroll view, and over-wide rows
/// let it scroll sideways, clipping the disclosure chevron and the start of every cluster name.
@MainActor enum PodSidebarValidation {
    static func check(_ fixture: PodBrowsingFixture, window: NSWindow, widths: [CGFloat]) async throws -> String {
        guard let stable = widths.first, widths.allSatisfy({ abs($0 - stable) < 1 }) else {
            throw Failure.resizedWithWindow(widths)
        }
        // The system split view owns the width now, so the sweep through our own bounds is gone;
        // what still matters is that it holds across a window resize and never scrolls sideways.
        var measured: [String] = []
        if let table = sidebar(in: window), let scroll = table.enclosingScrollView {
            guard table.frame.width <= scroll.contentView.bounds.width + 1 else {
                throw Failure.contentWiderThanColumn(table.frame.width)
            }
            measured.append(String(format: "%.1f<=%.1f", table.frame.width, scroll.contentView.bounds.width))
        }
        // The behaviour that matters is whether a user's drag survives a window resize: the system
        // divider is an NSSplitView divider, so it can be moved the way a drag would move it.
        if let split = splitView(in: window) {
            split.setPosition(220, ofDividerAt: 0)
            window.contentView?.layoutSubtreeIfNeeded()
            let dragged = sidebar(in: window)?.visibleRect.width ?? 0
            window.setContentSize(NSSize(width: 1_100, height: 760))
            try await PodBrowsingValidation.until { true }
            window.contentView?.layoutSubtreeIfNeeded()
            let afterResize = sidebar(in: window)?.visibleRect.width ?? 0
            measured.append(String(format: "dragged %.0f then %.0f after resize", dragged, afterResize))
            guard abs(dragged - afterResize) <= 1 else { throw Failure.measured(
                String(format: "drag lost: %.0f became %.0f", dragged, afterResize)
            ) }
        }
        return String(format: "width stable at %.0f across 1050x800 and 1000x600; ", stable)
            + "content never exceeds the column (\(measured.joined(separator: " ")))"
    }

    /// The pane's inset has to match the table's own, or the content rows above the table and its
    /// first column start at different x. The controls moved to the toolbar, so the comparison is
    /// now between the table's edge and its first cell rather than against a namespace field.
    static func checkPaneAlignment(window: NSWindow, table: NSTableView) throws -> String {
        guard let cell = (table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField,
              let content = window.contentView else { throw Failure.misaligned }
        let tableX = table.convert(table.bounds, to: content).minX
        let cellX = cell.convert(cell.bounds, to: content).minX
        guard abs((cellX - tableX) - PodsPaneMetrics.inset) <= 1 else {
            throw Failure.measured(String(format: "cell %.1f is %.1f from the table edge", cellX, cellX - tableX))
        }

        // The label must sit in the middle of its row, not against the top edge, and the row must
        // have room around it: a stretched text field draws its single line at the top.
        guard let row = cell.superview else { throw Failure.misaligned }
        let rowHeight = row.bounds.height
        let above = cell.frame.minY - row.bounds.minY
        let below = rowHeight - cell.frame.maxY
        guard rowHeight >= 26, above >= 4, abs(above - below) <= 1 else {
            throw Failure.measured(String(
                format: "host %.1f, label %.1f, above %.1f, below %.1f", rowHeight, cell.frame.height, above, below
            ))
        }
        return String(
            format: "first cell %.0fpt from the table edge; label centred in a %.0fpt row (%.1f above, %.1f below)",
            cellX - tableX, rowHeight, above, below
        )
    }

    private static func namespaceField(in window: NSWindow) -> NSTextField? {
        PodBrowsingValidation.windowRoot(window).flatMap {
            descendants($0).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Namespace" }
        }
    }

    private static func splitView(in window: NSWindow) -> NSSplitView? {
        window.contentView.flatMap { descendants($0).compactMap { $0 as? NSSplitView }.first }
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    /// SwiftUI's List is itself an NSTableView, so the sidebar is the one that is not the pod table.
    private static func sidebar(in window: NSWindow) -> NSTableView? {
        window.contentView.flatMap {
            descendants($0).compactMap { $0 as? NSTableView }.first { $0.identifier?.rawValue != "pod-table" }
        }
    }

    private enum Failure: Error {
        case resizedWithWindow([CGFloat])
        case contentWiderThanColumn(CGFloat)
        case misaligned
        case measured(String)
    }
}
#endif
