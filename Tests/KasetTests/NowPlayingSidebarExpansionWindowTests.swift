import CoreGraphics
import Testing
@testable import Kaset

/// The arithmetic of the window that opens a card into the Now Playing column.
///
/// The move is a single shape interpolation (`NowPlayingSidebarExpansionWindow`), so these are the
/// numbers that decide it: where its edges are at each point of the move, that the card's rounding is
/// gone by the end, and that the spring's overshoot cannot grow the window past the column — a window
/// wider than its surface is a page drawn outside the column.
@Suite("The card window growing into the Now Playing column", .tags(.model))
struct NowPlayingSidebarExpansionWindowTests {
    /// The column's surface, as the window's shape receives it.
    private static let surface = CGRect(x: 0, y: 0, width: 380, height: 760)

    /// A card in the middle of it: the lyric window's place on a 760pt column.
    private static let card = CGRect(x: 14, y: 486, width: 352, height: 140)

    private static func window(_ progress: CGFloat) -> CGRect {
        NowPlayingSidebarExpansionWindow.window(card: Self.card, surface: Self.surface, progress: progress)
    }

    @Test("At the start of a move the window is the card itself")
    func windowStartsAsTheCard() {
        #expect(Self.window(0) == Self.card)
    }

    @Test("At the end of a move the window is the whole column")
    func windowEndsAsTheColumn() {
        #expect(Self.window(1) == Self.surface)
    }

    @Test("Every edge travels its own distance, so the window grows out of the card rather than sliding")
    func edgesGrowOutOfTheCard() {
        let halfway = Self.window(0.5)

        // minX 14 → 0, minY 486 → 0, width 352 → 380, height 140 → 760.
        #expect(abs(halfway.minX - 7) < 0.001)
        #expect(abs(halfway.minY - 243) < 0.001)
        #expect(abs(halfway.width - 366) < 0.001)
        #expect(abs(halfway.height - 450) < 0.001)
    }

    @Test("A spring's overshoot stays on the column instead of growing past it")
    func overshootIsClamped() {
        #expect(Self.window(1.03) == Self.surface)
        #expect(Self.window(-0.03) == Self.card)
    }

    @Test("A page with no card behind it is never clipped to nothing")
    func noCardIsTheWholeSurface() {
        let window = NowPlayingSidebarExpansionWindow(card: nil, progress: 0, cornerRadius: 16)
        #expect(window.path(in: Self.surface).boundingRect == Self.surface)
    }

    @Test("The card's rounding is unwound by the time the window is the column")
    func roundingUnwinds() {
        // A rounded rect's bounding box is its rect either way, so the rounding is read where it is:
        // the card's top-left corner is outside the shape while it is rounded, and on it once square.
        let corner = CGPoint(x: Self.card.minX + 1, y: Self.card.minY + 1)
        let rounded = NowPlayingSidebarExpansionWindow(card: Self.card, progress: 0, cornerRadius: 16)
            .path(in: Self.surface)
        let square = NowPlayingSidebarExpansionWindow(card: Self.card, progress: 1, cornerRadius: 16)
            .path(in: Self.surface)

        #expect(!rounded.contains(corner))
        #expect(square.contains(corner))
    }
}
