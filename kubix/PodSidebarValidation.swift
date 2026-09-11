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
    }
}
#endif
