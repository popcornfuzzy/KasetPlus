import SwiftUI

// MARK: - AppAnimation

/// Centralized animation constants for consistent motion design throughout the app.
/// All animations respect the system's "Reduce Motion" accessibility setting.
enum AppAnimation {
    // MARK: - Duration Constants

    /// Quick interactions like button presses (0.15s)
    static let quick = Animation.easeOut(duration: 0.15)

    /// Standard UI transitions (0.25s)
    static let standard = Animation.easeInOut(duration: 0.25)

    /// Smooth, noticeable transitions (0.35s)
    static let smooth = Animation.easeInOut(duration: 0.35)

    /// Decorative, ambient animations (0.5s)
    static let ambient = Animation.easeInOut(duration: 0.5)

    // MARK: - Spring Animations

    /// Responsive spring for interactive elements
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.7)

    /// Bouncy spring for playful feedback
    static let bouncy = Animation.spring(response: 0.4, dampingFraction: 0.6)

    /// Snappy spring for quick snaps
    static let snappy = Animation.spring(response: 0.25, dampingFraction: 0.8)

    /// A card growing into the page it opens — and shrinking back into it.
    ///
    /// Short on purpose: the reader pressed a card, and the page has to feel like it was already
    /// there rather than being animated into place. Nearly critically damped, because the window's
    /// edge is the column's own edge by the end of the move: a card that bounced past it would read as
    /// a panel landing rather than as a card becoming the page.
    static let cardExpansion = Animation.spring(response: 0.3, dampingFraction: 0.88)

    /// A line change in the lyric sheet: the arriving row and every other visible row move one step
    /// along the emphasis falloff (`LyricLineEmphasis`) as one body. `smooth` is a spring with no
    /// bounce and zero velocity at both ends, and a duration it actually finishes in.
    ///
    /// The duration **is** the scroll lead, so the move ends on the frame the line starts being sung.
    /// See [ADR-0018](../adr/0018-karaoke-lyrics-animation.md).
    static let lyricEmphasis = Animation.smooth(duration: Self.lyricChangeSeconds)

    /// The sheet's travel to the next line: the same span, on a **timing curve** rather than a spring.
    ///
    /// The scroll view runs this one itself, and a cubic Bézier is what it can lay over a distance: a
    /// long ease-out that leaves at once and bleeds the last of the move off slowly, instead of the
    /// symmetric curve over one line's height that read as a linear slide.
    static let lyricTravel = Animation.timingCurve(0.22, 0.9, 0.28, 1, duration: Self.lyricChangeSeconds)

    /// The lead a line change gets, in seconds: the span both lyric animations take.
    private static let lyricChangeSeconds = KaraokeTiming.standard.scrollLeadMs / 1000

    // MARK: - Stagger Delays

    /// Base delay for staggered list animations
    static let staggerDelay: Double = 0.05

    /// Maximum stagger delay to prevent long waits
    static let maxStaggerDelay: Double = 0.5

    /// Calculate stagger delay for a given index
    static func stagger(for index: Int, base: Double = staggerDelay) -> Double {
        min(Double(index) * base, self.maxStaggerDelay)
    }
}
