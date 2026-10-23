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

    /// The surface a sidebar video is drawn in. The height is whole points — a page lays out in
    /// whole points, so a fractional surface left a strip of itself outside its own page, which
    /// is the black hairline along the video's edge — and the surface says whether it is the
    /// video's own shape, which decides between filling it (no black edge) and letterboxing the
    /// whole picture.
    static let videoSurfaces: [(name: String, observed: Double?, available: CGFloat, height: CGFloat, matches: Bool)] = [
        ("a landscape video fills a surface built to its ratio", 854.0 / 480.0, 900, 169, true),
        ("a portrait video is clamped, so the whole picture stays visible", 9.0 / 16.0, 900, 400, false),
        ("a wide video is capped, so the whole picture stays visible", 3.0, 900, 150, false),
        ("a short column cuts the surface, so the whole picture stays visible", 854.0 / 480.0, 470, 154, false),
        ("before the video reports its ratio, the fallback box is not its shape", nil, 900, 169, false),
    ]

    @Test(arguments: Self.videoSurfaces)
    func theVideoSurfaceIsWholePointsAndSaysWhetherItIsTheVideosShape(
        _ testCase: (name: String, observed: Double?, available: CGFloat, height: CGFloat, matches: Bool)
    ) {
        let box = SidebarVideoAspect.box(
            forWidth: 300,
            observedAspectRatio: testCase.observed,
            availableHeight: testCase.available,
            reservedHeight: NowPlayingSidebarLayout.reservedHeight
        )

        #expect(box.height == testCase.height, "\(testCase.name)")
        #expect(box.matchesVideoShape == testCase.matches, "\(testCase.name)")
    }

    /// The surface is *sized* by the picture's ratio, so a surface that attaches before the video
    /// reports one would keep the 16:9 fallback — the letterboxed shape with black around the
    /// picture. It asks the page instead of waiting for the next state update to carry the size.
    @MainActor
    @Test func theSurfaceAsksThePageForThePictureItIsAboutToDraw() {
        let script = SingletonPlayerWebView.videoDimensionsRequestScript()

        #expect(script.contains("videoWidth"))
        #expect(script.contains("videoHeight"))
        #expect(script.contains("VIDEO_DIMENSIONS"))
        #expect(script.contains("singletonPlayer"))
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

    /// The box is only the picture's shape once the page has reported it. Until then it is the 16:9
    /// fallback, and `contain` in it is a letterbox around anything that is not 16:9 — the black
    /// bars around the video right after switching to it. Filling instead is invisible.
    @Test func aSurfaceOfUnknownShapeFillsThePicture() {
        let box = SidebarVideoAspect.box(
            forWidth: 300,
            observedAspectRatio: nil,
            availableHeight: 900,
            reservedHeight: NowPlayingSidebarLayout.reservedHeight
        )
        #expect(!box.matchesVideoShape)
        #expect(SidebarVideoAspect.fillsSurface(box, shapeIsKnown: false))
    }

    @Test func aSurfaceOfKnownShapeFollowsItsOwnRule() {
        let matching = SidebarVideoAspect.box(
            forWidth: 300,
            observedAspectRatio: 854.0 / 480.0,
            availableHeight: 900,
            reservedHeight: NowPlayingSidebarLayout.reservedHeight
        )
        #expect(SidebarVideoAspect.fillsSurface(matching, shapeIsKnown: true))

        // A clamped portrait keeps the whole picture: that letterbox is the shape the column
        // imposed, not a fallback.
        let clamped = SidebarVideoAspect.box(
            forWidth: 300,
            observedAspectRatio: 9.0 / 16.0,
            availableHeight: 900,
            reservedHeight: NowPlayingSidebarLayout.reservedHeight
        )
        #expect(!SidebarVideoAspect.fillsSurface(clamped, shapeIsKnown: true))
    }

    /// The WebView's view hierarchy follows the same single-writer rule as the DOM presentation.
    /// A parked host that takes the WebView hides the picture everywhere else, and the surface
    /// that lost it is not updated (none of its inputs changed), so it never gets it back.
    @Test func onlyThePresentationOwnerMayHostTheWebView() {
        let sidebar = NSObject()
        let hidden = NSObject()

        // A video surface always may: it is the surface the user asked for.
        #expect(PlayerSurfaceOwnership.mayHost(
            isExpanded: true, owner: sidebar, container: hidden, presentationEnabled: true))

        // The parked layer may while no surface is active, and while it owns the surface.
        #expect(PlayerSurfaceOwnership.mayHost(
            isExpanded: false, owner: nil, container: hidden, presentationEnabled: false))
        #expect(PlayerSurfaceOwnership.mayHost(
            isExpanded: false, owner: hidden, container: hidden, presentationEnabled: true))

        // Never while a video surface owns the presentation.
        #expect(!PlayerSurfaceOwnership.mayHost(
            isExpanded: false, owner: sidebar, container: hidden, presentationEnabled: true))
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

    /// A WebView that is resized and hosted again draws the first frames of the picture at the
    /// size the page had before, so the sidebar keeps the surface mounted at the video's size
    /// behind the artwork and the toggle is only an opacity change.
    @Test func theSidebarKeepsTheVideoSurfaceMountedBehindItsArtwork() {
        #expect(SidebarVideoHosting.keepsSurface(
            isSidebarVisible: true,
            hasVideoSurface: true,
            hasPendingVideo: true,
            isFullscreenPodcastPresented: false
        ))

        // Nowhere to keep it: the column is closed, so the hidden layer hosts as usual.
        #expect(!SidebarVideoHosting.keepsSurface(
            isSidebarVisible: false,
            hasVideoSurface: true,
            hasPendingVideo: true,
            isFullscreenPodcastPresented: false
        ))

        // Nothing to draw: no video for this item, or no id to play it for.
        #expect(!SidebarVideoHosting.keepsSurface(
            isSidebarVisible: true,
            hasVideoSurface: false,
            hasPendingVideo: true,
            isFullscreenPodcastPresented: false
        ))
        #expect(!SidebarVideoHosting.keepsSurface(
            isSidebarVisible: true,
            hasVideoSurface: true,
            hasPendingVideo: false,
            isFullscreenPodcastPresented: false
        ))

        // The fullscreen podcast view has its own slot: a second surface would fight it for the
        // one WebView.
        #expect(!SidebarVideoHosting.keepsSurface(
            isSidebarVisible: true,
            hasVideoSurface: true,
            hasPendingVideo: true,
            isFullscreenPodcastPresented: true
        ))
    }
}
