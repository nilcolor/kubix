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
        var measured: [String] = []
        for width in [AppStore.sidebarWidthMinimum, AppStore.sidebarWidthMaximum, AppStore.sidebarWidthDefault] {
            fixture.actions.setSidebarWidth(width)
            try await PodBrowsingValidation.until {
                abs((sidebar(in: window)?.visibleRect.width ?? 0) - width) < 1
            }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let table = sidebar(in: window), let scroll = table.enclosingScrollView,
                  table.frame.width <= scroll.contentView.bounds.width + 1 else {
                throw Failure.contentWiderThanColumn(width)
            }
            measured.append(String(format: "%.0f:%.1f<=%.1f", width, table.frame.width, scroll.contentView.bounds.width))
        }
        // Out of bounds in both directions, to prove the clamp is the store's and not the drag's.
        fixture.actions.setSidebarWidth(10)
        try await PodBrowsingValidation.until {
            abs((sidebar(in: window)?.visibleRect.width ?? 0) - AppStore.sidebarWidthMinimum) < 1
        }
        fixture.actions.setSidebarWidth(5_000)
        try await PodBrowsingValidation.until {
            abs((sidebar(in: window)?.visibleRect.width ?? 0) - AppStore.sidebarWidthMaximum) < 1
        }
        fixture.actions.setSidebarWidth(AppStore.sidebarWidthDefault)
        return String(format: "width stable at %.0f across 1050x800 and 1000x600; ", stable)
            + "content never exceeds the column (\(measured.joined(separator: " "))); "
            + "out-of-range widths clamp to the store's bounds"
    }

    /// The pane has one leading edge: the namespace control, the status line and the table's first
    /// column all start at the same x, or the eye reads the column as broken.
    static func checkPaneAlignment(window: NSWindow, table: NSTableView) throws -> String {
        guard let namespace = namespaceField(in: window),
              let cell = (table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField,
              let content = window.contentView else { throw Failure.misaligned }
        let namespaceX = namespace.convert(namespace.bounds, to: content).minX
        let cellX = cell.convert(cell.bounds, to: content).minX
        guard abs(namespaceX - cellX) <= 1 else {
            throw Failure.measured(String(format: "namespace %.1f vs cell %.1f", namespaceX, cellX))
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
            format: "leading x %.1f shared; label centred in a %.0fpt row (%.1f above, %.1f below)",
            namespaceX, rowHeight, above, below
        )
    }

    private static func namespaceField(in window: NSWindow) -> NSTextField? {
        window.contentView.flatMap {
            descendants($0).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Namespace" }
        }
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
