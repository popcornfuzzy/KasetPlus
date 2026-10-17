import CoreGraphics
import Testing

@testable import Kaset

// MARK: - SidebarVideoAspectTests

/// The sidebar video follows the content's own ratio instead of locking to one, but stays
/// reasonable: portrait is floored before it can become a tower, wide letterbox is capped,
/// and the height never leaves the sidebar's own floor/ceiling.
struct SidebarVideoAspectTests {
    @Test func fallbackRatioBeforeDimensionsArrive() {
        #expect(SidebarVideoAspect.clamped(nil) == SidebarVideoAspect.fallback)
        #expect(SidebarVideoAspect.clamped(0) == SidebarVideoAspect.fallback)
        #expect(SidebarVideoAspect.clamped(-1) == SidebarVideoAspect.fallback)
        #expect(SidebarVideoAspect.clamped(.nan) == SidebarVideoAspect.fallback)
        #expect(SidebarVideoAspect.clamped(.infinity) == SidebarVideoAspect.fallback)
    }

    @Test func passthroughForSaneRatios() {
        #expect(abs(SidebarVideoAspect.clamped(16.0 / 9.0) - CGFloat(16.0 / 9.0)) < 0.0001)
        #expect(SidebarVideoAspect.clamped(1.0) == 1.0)
        #expect(SidebarVideoAspect.clamped(2.0) == 2.0)
    }

    @Test func verticalVideoIsFlooredBeforeItBecomesATower() {
        // A 9:16 phone video (0.5625) would be a full-height tower; it lands on the floor.
        #expect(SidebarVideoAspect.clamped(9.0 / 16.0) == SidebarVideoAspect.minimum)
        #expect(SidebarVideoAspect.clamped(0.01) == SidebarVideoAspect.minimum)
    }

    @Test func wideLetterboxIsCapped() {
        #expect(SidebarVideoAspect.clamped(99) == SidebarVideoAspect.maximum)
    }

    @Test func heightFollowsTheClampedRatioWithinBounds() {
        let height = SidebarVideoAspect.height(forWidth: 380, observedAspectRatio: 16.0 / 9.0)
        #expect(abs(height - 380 / (16.0 / 9.0)) < 0.001)
    }

    @Test func verticalVideoHeightStaysCapped() {
        let height = SidebarVideoAspect.height(forWidth: 380, observedAspectRatio: 9.0 / 16.0)
        #expect(height <= SidebarVideoAspect.maxHeight)
        #expect(height >= SidebarVideoAspect.minHeight)
    }

    @Test func fallbackHeightForWideColumn() {
        let height = SidebarVideoAspect.height(forWidth: 560, observedAspectRatio: nil)
        #expect(abs(height - 560 / (16.0 / 9.0)) < 0.001)
    }

    @Test func artworkStaysSquareForMusic() {
        #expect(SidebarVideoAspect.artworkAspectRatio(isPodcast: false, observedAspectRatio: nil) == 1)
        #expect(SidebarVideoAspect.artworkAspectRatio(isPodcast: false, observedAspectRatio: 16.0 / 9.0) == 1)
    }

    @Test func artworkIsFixedSixteenByNineForPodcasts() {
        // Fixed 16:9: the observed video ratio is deliberately ignored — reading it
        // re-rendered the sidebar mid-layout and crashed in `NSProgressIndicator setFont:`.
        let fallback = SidebarVideoAspect.artworkAspectRatio(isPodcast: true, observedAspectRatio: nil)
        #expect(abs(fallback - CGFloat(16.0 / 9.0)) < 0.0001)
        let observed = SidebarVideoAspect.artworkAspectRatio(isPodcast: true, observedAspectRatio: 4.0 / 3.0)
        #expect(abs(observed - CGFloat(16.0 / 9.0)) < 0.0001)
        let extreme = SidebarVideoAspect.artworkAspectRatio(isPodcast: true, observedAspectRatio: 9.0 / 16.0)
        #expect(abs(extreme - CGFloat(16.0 / 9.0)) < 0.0001)
    }
}
