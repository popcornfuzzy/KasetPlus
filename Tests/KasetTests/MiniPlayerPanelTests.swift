import AppKit
import CoreGraphics
import Foundation
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

    // MARK: - Presentation Ownership

    @Test func expandedRequestAlwaysWinsOwnership() {
        let sidebar = NSObject()
        let hidden = NSObject()
        #expect(PlayerSurfaceOwnership.shouldApply(
            isExpanded: true, owner: sidebar, currentOwner: hidden, presentationEnabled: true))
        #expect(PlayerSurfaceOwnership.shouldApply(
            isExpanded: true, owner: sidebar, currentOwner: nil, presentationEnabled: false))
    }

    @Test func parkingRequestFromNonOwnerNeverTearsDownALiveSurface() {
        // The toggle-ON race: the dying hidden host emits expanded:false after the
        // sidebar applied expanded:true. Ignoring it is what makes the video come
        // back every time instead of about half the time.
        let sidebar = NSObject()
        let hidden = NSObject()
        #expect(!PlayerSurfaceOwnership.shouldApply(
            isExpanded: false, owner: hidden, currentOwner: sidebar, presentationEnabled: true))
    }

    @Test func parkingRequestAppliesWithoutAnOwnerOrFromTheOwner() {
        let hidden = NSObject()
        #expect(PlayerSurfaceOwnership.shouldApply(
            isExpanded: false, owner: hidden, currentOwner: nil, presentationEnabled: false))
        #expect(PlayerSurfaceOwnership.shouldApply(
            isExpanded: false, owner: hidden, currentOwner: hidden, presentationEnabled: true))
        // Inactive surface, someone else's stale container: safe to park.
        #expect(PlayerSurfaceOwnership.shouldApply(
            isExpanded: false, owner: hidden, currentOwner: NSObject(), presentationEnabled: false))
    }

    @Test func dismantleReleasesOwnershipOnlyForTheOwner() {
        let sidebar = NSObject()
        #expect(PlayerSurfaceOwnership.shouldReleaseOwner(container: sidebar, currentOwner: sidebar))
        #expect(!PlayerSurfaceOwnership.shouldReleaseOwner(container: NSObject(), currentOwner: sidebar))
        #expect(!PlayerSurfaceOwnership.shouldReleaseOwner(container: sidebar, currentOwner: nil))
    }

    // MARK: - WebView Host Handoff

    @MainActor
    @Test func hostDismantleIsTheStaticProtocolRequirement() {
        // `NSViewRepresentable.dismantleNSView` is a *static* requirement. Written as an
        // instance method it compiles silently and is never called, which is exactly how the
        // podcast-fullscreen handoff did nothing for two attempts: the WebView was left
        // orphaned in the removed overlay (window == nil) while audio kept playing, and the
        // sidebar was black until the window was closed and reopened. This binding stops
        // compiling if the method ever regresses to an instance method again.
        let dismantle: @MainActor (NSView, ()) -> Void = PersistentPlayerView.dismantleNSView
        _ = dismantle
    }

    /// The surviving-host contract: the shared WebView must never be left without a
    /// container when the surface that held it goes away.
    private static let hostContract: [(name: String, candidates: [PlayerWebViewHosting.Candidate], expected: Int?)] = [
        (
            "the sidebar takes over when the fullscreen overlay closes",
            [.init(isExpanded: true, isInWindow: true)], 0
        ),
        (
            "the parked layer takes over when the video surface is switched off",
            [.init(isExpanded: false, isInWindow: true)], 0
        ),
        (
            "a video surface outranks the parked layer",
            [.init(isExpanded: true, isInWindow: true), .init(isExpanded: false, isInWindow: true)], 0
        ),
        (
            "a surface that is not laid out yet still outranks the parked layer",
            [.init(isExpanded: true, isInWindow: false), .init(isExpanded: false, isInWindow: true)], 0
        ),
        (
            "ties go to the most recently registered host",
            [.init(isExpanded: true, isInWindow: true), .init(isExpanded: true, isInWindow: true)], 1
        ),
        ("no host left means no handoff", [], nil),
    ]

    @Test(arguments: hostContract)
    func theSurvivingHostIsChosenByTheContract(
        _ testCase: (name: String, candidates: [PlayerWebViewHosting.Candidate], expected: Int?)
    ) {
        #expect(
            PlayerWebViewHosting.preferredHost(testCase.candidates) == testCase.expected,
            "\(testCase.name)"
        )
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
