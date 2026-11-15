import SwiftUI

// MARK: - NowPlayingSidebarCardExpansion

/// A page arriving from the card that opened it, or leaving back into it.
///
/// A card and the page it opens are not two states of one view: a three-line lyric window and a
/// scrolling sheet, a single up-next row and the queue's table. So the hand-off is not a morph of the
/// content — it is one **window**: the card's own rect, carrying the card's own rounding, growing
/// until it is the whole column while the page inside it is drawn at its final size from the first
/// frame. The window is the only thing that moves, and the content it uncovers never re-lays out,
/// which is why the move cannot look like two views being crossfaded.
struct NowPlayingSidebarCardExpansion {
    /// Which way the move runs.
    ///
    /// Both directions are the same move seen from different ends, driven by the same progress value:
    /// an opening takes the window from the card to the column, and a closing takes it back.
    enum Direction {
        case opening
        case closing
    }

    /// The page inside the window.
    let page: NowPlayingSidebarPage

    let direction: Direction

    /// The card's rect, in the column's own coordinates, at the moment the move started.
    ///
    /// A recorded rect rather than a live measurement: while the move runs the card is drawn under a
    /// fading overview (or not drawn at all), so there is nothing on screen left to measure.
    let window: CGRect

    /// The card's rounding, so the window begins as the card's own shape and reaches the page's
    /// square corners only as it becomes the column.
    let cornerRadius: CGFloat

    /// Distinguishes this move from a later one, so a completion that arrives after the reader has
    /// already changed their mind cannot tear down the move that replaced it.
    let generation: Int

    /// When the move began, for the diagnostic: a move that lands in a millisecond never ran (an
    /// animatable shape with no previous frame to interpolate from), and the reader would see the page
    /// appear at the card's size.
    let startedAt: Date
}

// MARK: - NowPlayingSidebarCardWindows

/// Where the overview's cards sit, in the column's own coordinates.
///
/// A reference box rather than view state on purpose. The cards are measured whenever the overview
/// scrolls or the column is resized, and a state write per measurement re-evaluates the whole column
/// — artwork, canvas, lyric window, both cards — for a rect that is only ever read at the instant a
/// card is opened or a page is closed. Nothing draws this box, so nothing has to be invalidated when
/// it changes.
@MainActor
final class NowPlayingSidebarCardWindows {
    private var windows: [NowPlayingSidebarPage: CGRect] = [:]

    subscript(page: NowPlayingSidebarPage) -> CGRect? {
        get { self.windows[page] }
        set { self.windows[page] = newValue }
    }
}

// MARK: - NowPlayingSidebarExpansionWindow

/// The card growing into the column, as the shape that uncovers the page.
///
/// A `Shape` because a shape's `animatableData` is the one number the whole move runs on: every frame
/// is a single interpolation of the window, so its rect and its rounding cannot fall out of step the
/// way a stack of separately animated frames eventually does.
struct NowPlayingSidebarExpansionWindow: Shape {
    /// The card the page grows out of, or `nil` when no move is running — the shape is then the
    /// surface itself, which is what a page at rest is clipped to.
    var card: CGRect?

    /// Progress of the move: `0` is the card, `1` is the whole surface.
    var progress: CGFloat

    /// The card's rounding, unwound across the move.
    var cornerRadius: CGFloat

    var animatableData: CGFloat {
        get { self.progress }
        set { self.progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard let card else { return Path(rect) }

        let progress = Self.clamp(self.progress)
        return Path(
            roundedRect: Self.window(card: card, surface: rect, progress: progress),
            // The card's corners unwind as it grows: the page is square, and a window that reached
            // square early would read as a rounded sheet shrinking inside the column rather than as a
            // card becoming it.
            cornerRadius: max(0, self.cornerRadius) * (1 - progress),
            style: .continuous
        )
    }

    /// The window's rect at a point of the move.
    ///
    /// Progress is clamped: the move is a spring, an overshoot of a couple of percent would put the
    /// window past the column's own edges for the last frames of the settle, and a window that is
    /// already the surface has nothing left to grow into.
    static func window(card: CGRect, surface: CGRect, progress: CGFloat) -> CGRect {
        let progress = self.clamp(progress)
        return CGRect(
            x: card.minX + (surface.minX - card.minX) * progress,
            y: card.minY + (surface.minY - card.minY) * progress,
            width: card.width + (surface.width - card.width) * progress,
            height: card.height + (surface.height - card.height) * progress
        )
    }

    private static func clamp(_ progress: CGFloat) -> CGFloat {
        min(max(progress, 0), 1)
    }
}
