import CoreGraphics
import Testing
@testable import Kaset

/// The fullscreen player's artwork has to take the room its column has left, not a share of the stage.
/// The transport row only draws on hover but keeps its slot, so revealing it cannot overlap the title —
/// and the slot is part of what the artwork has to leave room for. These pin the arithmetic so it
/// cannot silently regress.
@Suite(.tags(.model))
struct FullscreenArtworkGeometryTests {
    /// The window from the report: 1490pt wide and short, so the stage is its height minus the player's
    /// own chrome (see the stage arithmetic in `FullscreenNowPlayingView.body`) and the artwork column is
    /// 48% of the stage width.
    private static let reportedShortWindow = FullscreenArtworkGeometry(columnWidth: 699, stageHeight: 716)

    /// The same window made taller — the state the report calls correct, which was only correct because
    /// the stage had grown past the height at which the old fraction reached the cap.
    private static let reportedTallWindow = FullscreenArtworkGeometry(columnWidth: 699, stageHeight: 900)

    @Test("A short window gives the artwork the size a tall one does")
    func shortWindowReachesTheCap() {
        // 716 - 216 = 500 of leftover, well past the 380 cap.
        #expect(Self.reportedShortWindow.side == FullscreenArtworkGeometry.maxSide)
        #expect(Self.reportedTallWindow.side == FullscreenArtworkGeometry.maxSide)
        #expect(Self.reportedShortWindow.side == Self.reportedTallWindow.side)
    }

    @Test("The empty room a short window used to leave is what the artwork takes")
    func shortWindowLeavesNoRoomUnused() {
        let stage = Self.reportedShortWindow.stageHeight
        let wasGiven = stage * 0.46
        #expect(Self.reportedShortWindow.side > wasGiven)
    }

    @Test("Between its smallest and largest, the artwork takes exactly what the column has left")
    func artworkTakesTheLeftover() {
        for stage in stride(from: 420.0, through: 580.0, by: 20.0) {
            let geometry = FullscreenArtworkGeometry(columnWidth: 699, stageHeight: stage)
            let expected = stage - Double(FullscreenArtworkGeometry.reservedHeight)
            // Compared as `Double` on purpose: `#expect`'s expansion of `==` between two `CGFloat`
            // expressions reports a failure here for operands whose bit patterns are identical, and this
            // is an exactness check.
            #expect(
                Double(geometry.side) == expected,
                "at stage \(stage)"
            )
        }
    }

    @Test("The artwork grows as the window does, and then stops at its largest")
    func artworkGrowsThenStops() {
        func side(_ stage: CGFloat) -> CGFloat {
            FullscreenArtworkGeometry(columnWidth: 699, stageHeight: stage).side
        }

        // 420 - 216 = 204, 500 - 216 = 284, 580 - 216 = 364, and 596 is where the cap takes over.
        #expect(side(420) == 204)
        #expect(side(500) == 284)
        #expect(side(580) == 364)
        #expect(side(600) == FullscreenArtworkGeometry.maxSide)
        #expect(side(900) == FullscreenArtworkGeometry.maxSide)
        #expect(side(580) > side(500))
        #expect(side(500) > side(420))
    }

    @Test("A narrow column caps the artwork even when the window is tall")
    func columnWidthCapsTheArtwork() {
        #expect(FullscreenArtworkGeometry(columnWidth: 300, stageHeight: 900).side == 300)
        #expect(FullscreenArtworkGeometry(columnWidth: 380, stageHeight: 900).side == FullscreenArtworkGeometry.maxSide)
    }

    @Test("A very short window stops at the smallest artwork rather than a sliver")
    func veryShortWindowStopsAtTheSmallest() {
        #expect(FullscreenArtworkGeometry(columnWidth: 699, stageHeight: 320).side == FullscreenArtworkGeometry.minSide)
        // Even with no height at all — the first layout pass, before the stage is known — the floor holds.
        #expect(FullscreenArtworkGeometry(columnWidth: 699, stageHeight: 0).side == FullscreenArtworkGeometry.minSide)
    }

    @Test("The stage must fit the artwork and what the column draws besides it")
    func theColumnFitsItsStage() {
        // The invariant the fraction never had a reason to respect: wherever the artwork is not held
        // down by its own floor or cap, the column's fixed contents plus the art are the whole stage.
        for stage in stride(from: 420.0, through: 600.0, by: 10.0) {
            let side = FullscreenArtworkGeometry(columnWidth: 699, stageHeight: stage).side
            #expect(
                side + FullscreenArtworkGeometry.reservedHeight <= stage,
                "at stage \(stage): \(side) + \(FullscreenArtworkGeometry.reservedHeight)"
            )
        }
    }

    @Test("The largest artwork is still within the card's decode target")
    func largestArtworkIsSharp() {
        // The cap doubles as the decode target, so a Retina card must not draw bigger than what is
        // downloaded for it (see `maxSide`).
        #expect(FullscreenArtworkGeometry.maxSide * 2 <= 760)
        #expect(FullscreenArtworkGeometry.minSide < FullscreenArtworkGeometry.maxSide)
    }
}
