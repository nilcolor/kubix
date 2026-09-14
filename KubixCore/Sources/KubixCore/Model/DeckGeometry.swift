import Foundation

/// The session deck's share of the detail pane, from a cursor position.
public enum DeckGeometry {
    /// `y` and `top` must be in the same space: a drag reports window coordinates, which include
    /// everything above the pane, while the fraction is of the pane alone. Subtracting the pane's
    /// own origin is what stops a press — a drag of no distance — from moving the boundary.
    @MainActor public static func fraction(at y: Double, top: Double, total: Double) -> Double {
        guard total > 0 else { return AppStore.deckFractionDefault }
        return 1 - (y - top) / total
    }
}
