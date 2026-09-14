import Foundation
import KubixCore
import Testing

/// The deck divider's arithmetic, which is only correct if the pane's own offset is subtracted.
@Suite @MainActor struct DeckGeometryTests {
    @Test func aPressAtTheBoundaryKeepsTheFractionItWasDrawnAt() {
        // A pane 400pt tall starting 120pt down the window, with the deck holding half of it: the
        // boundary is drawn 200pt into the pane, which is 320 in the space a drag reports.
        #expect(DeckGeometry.fraction(at: 320, top: 120, total: 400) == 0.5)
        // Without the offset the same press would claim the deck wants a fifth of the pane.
        #expect(abs(DeckGeometry.fraction(at: 320, top: 0, total: 400) - 0.2) < 1e-9)
    }

    @Test func draggingUpwardGivesTheDeckMoreOfThePane() {
        #expect(DeckGeometry.fraction(at: 220, top: 120, total: 400) == 0.75)
        #expect(DeckGeometry.fraction(at: 420, top: 120, total: 400) == 0.25)
        // A pane with no height cannot be divided, so the default stands rather than a division by zero.
        #expect(DeckGeometry.fraction(at: 220, top: 120, total: 0) == AppStore.deckFractionDefault)
    }
}
