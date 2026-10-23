import CoreGraphics
import Foundation

// MARK: - SidebarVideoAspect

/// Aspect-ratio arithmetic for the right sidebar video.
///
/// The video follows the content's own ratio instead of locking to one, but a vertical phone
/// video would become a tower that pushes everything else off the column — so the ratio is
/// clamped before the height is derived from it. Kept as a plain value so the clamping can be
/// reasoned about and tested without a window on screen.
enum SidebarVideoAspect {
    /// Floor for portrait content: a 9:16 vertical video (0.56) lands here instead of
    /// becoming a full-height tower.
    static let minimum: CGFloat = 0.75
    /// Ceiling for wide letterbox content.
    static let maximum: CGFloat = 2.4
    /// Ratio used before the player has reported the content's own.
    static let fallback: CGFloat = 16.0 / 9.0
    /// Floor/ceiling for the video height, matching the artwork's own bounds.
    static let minHeight: CGFloat = 150
    static let maxHeight: CGFloat = 520

    /// The ratio the sidebar video is laid out at for an observed video ratio.
    static func clamped(_ observed: Double?) -> CGFloat {
        guard let observed, observed.isFinite, observed > 0 else { return Self.fallback }
        return min(max(CGFloat(observed), Self.minimum), Self.maximum)
    }

    /// Height for a video of the clamped ratio in a column of `width`, bounded to the
    /// sidebar's own floor/ceiling.
    static func height(forWidth width: CGFloat, observedAspectRatio: Double?) -> CGFloat {
        let ratio = Self.clamped(observedAspectRatio)
        guard ratio > 0 else { return Self.minHeight }
        let raw = width / ratio
        return min(max(raw, Self.minHeight), Self.maxHeight)
    }

    /// The surface the sidebar draws a video in.
    struct Box: Equatable {
        /// Height of the surface, in whole points.
        let height: CGFloat
        /// Whether the surface is the video's own shape.
        ///
        /// A surface sized from the video's own ratio must draw the picture edge to edge: the
        /// only difference left is the fraction of a point that layout cannot represent, and
        /// cropping that is invisible while letterboxing it draws a black hairline. A surface
        /// whose ratio the column imposed — the fallback before the video reports its own, a
        /// clamped portrait, a short column — keeps the whole picture instead.
        let matchesVideoShape: Bool
    }

    /// The surface for a video of `observedAspectRatio` in a column `width` wide, with
    /// `availableHeight` to give it after `reservedHeight`.
    static func box(
        forWidth width: CGFloat,
        observedAspectRatio: Double?,
        availableHeight: CGFloat,
        reservedHeight: CGFloat
    ) -> Box {
        guard width.isFinite, width > 0 else {
            return Box(height: Self.minHeight, matchesVideoShape: false)
        }

        let observed = observedAspectRatio.flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil }
        let ratio = Self.clamped(observedAspectRatio)
        let natural = width / ratio
        let ceiling = availableHeight > 0
            ? max(Self.minHeight, availableHeight - reservedHeight)
            : Self.maxHeight
        let height = min(min(max(natural, Self.minHeight), Self.maxHeight), ceiling)
        let matches = observed == ratio
            && natural >= Self.minHeight
            && natural <= Self.maxHeight
            && natural <= ceiling

        // Whole points: a page lays out in whole points, so a fractional surface leaves a strip
        // of itself outside its own page — the black hairline along the video's edge.
        return Box(height: height.rounded(), matchesVideoShape: matches)
    }

    /// Whether the surface must draw the picture edge to edge.
    ///
    /// A box built to the picture's own ratio fills it. So does a box whose shape is not known yet:
    /// that is the 16:9 fallback, and letterboxing a picture that is not 16:9 inside it is the
    /// frame of black around the video that shows up for the first moments after switching to it.
    /// A box whose ratio the column imposed (a clamped portrait, a short column) keeps the whole
    /// picture instead, so the black there is the letterbox the user asked for by having a column
    /// too short for the picture.
    static func fillsSurface(_ box: Box, shapeIsKnown: Bool) -> Bool {
        guard shapeIsKnown else { return true }
        return box.matchesVideoShape
    }

    /// Aspect ratio the sidebar artwork is laid out at: square album art for music, fixed 16:9
    /// for podcasts (the episode still).
    ///
    /// Deliberately *not* the observed video ratio: that value arrives from the WebView
    /// mid-layout and changes the artwork height inside the layout pass, which re-enters
    /// AppKit constraint resolution while SwiftUI is updating its AppKit-backed
    /// `ProgressView` and crashes in `NSProgressIndicator setFont:` (see crash 20:23 17.10).
    /// A still image needs no live ratio tracking — 16:9 matches the episode stills.
    static func artworkAspectRatio(isPodcast: Bool, observedAspectRatio _: Double? = nil) -> CGFloat {
        guard isPodcast else { return 1 }
        return Self.fallback
    }
}

// MARK: - PlayerWebViewHosting

/// Which container keeps the shared WebView when another one goes away.
///
/// There is exactly one `WKWebView`, so every video surface is a container it is
/// moved into. A surface that disappears takes its container with it, and the WebView
/// that was living there loses its superview when that container is released — both
/// `window` and `superview` become `nil`.
///
/// That is the black sidebar after leaving podcast fullscreen: the podcast overlay
/// owns the WebView while it is up, and its removal orphaned it. Audio kept playing
/// (the WebKit content process does not care), the sidebar had no view to draw in,
/// and closing and reopening the window only looked like the fix because that rebuilds
/// the layout and re-parents the WebView (see ``SingletonPlayerWebView/registerHost``).
///
/// SwiftUI has no reason to update the sidebar's own representable when the overlay
/// disappears — none of the values it was given changed — so the handoff has to be
/// made by the host that goes away, at the moment it goes away.
enum PlayerWebViewHosting {
    /// A registered container, reduced to the facts the choice depends on.
    struct Candidate: Equatable {
        /// The surface wants the video (the sidebar video or the podcast slot), rather
        /// than being the hidden parker.
        let isExpanded: Bool
        /// The container is attached to a window, so the WebView would really be drawn.
        let isInWindow: Bool
    }

    /// Index of the host that should take the WebView, or `nil` when none is left.
    ///
    /// `candidates` is in registration order (oldest first), so ties go to the most
    /// recent host — the one the user just arrived at. A video surface outranks the
    /// parked layer, and being in a window outranks not being laid out yet.
    static func preferredHost(_ candidates: [Candidate]) -> Int? {
        func rank(_ candidate: Candidate) -> Int {
            (candidate.isExpanded ? 2 : 0) + (candidate.isInWindow ? 1 : 0)
        }
        guard let best = candidates.map(rank).max() else { return nil }
        return candidates.indices.last { rank(candidates[$0]) == best }
    }
}

// MARK: - SidebarVideoHosting

/// Where the sidebar's video surface lives.
///
/// The surface keeps the shared WebView even while the artwork is on top of it. Parking the
/// WebView in the invisible 1×1 layer and hosting it again on every toggle is what made the
/// picture wrong on arrival: a page lays out in CSS pixels, but the video's own rendering layer
/// takes its size asynchronously, and for the first ~370 ms after the WebView is resized it is
/// still drawn at the size the page had before (a small picture in the middle of a black
/// surface). Nothing in the DOM reports that size, so the only place to fix it is here: a
/// surface that is never resized never draws a frame at the wrong size, and the toggle becomes
/// what it should have been — an opacity change.
///
/// The artwork is drawn above it, so what the reader sees does not change; the cost is that the
/// video keeps decoding behind the artwork while the sidebar is open, which is the same stream
/// that is already playing its audio.
enum SidebarVideoHosting {
    /// Whether the sidebar holds the WebView at the video's own size.
    ///
    /// - The sidebar must be on screen: with the column closed there is no place to keep the
    ///   surface, and the hidden audio layer hosts it as usual.
    /// - A video must exist for the current playback item, with an id to draw it for.
    /// - The fullscreen podcast view has its own surface in the window's own layout: keeping the
    ///   sidebar's surface alive underneath would be a second host claiming the same WebView.
    static func keepsSurface(
        isSidebarVisible: Bool,
        hasVideoSurface: Bool,
        hasPendingVideo: Bool,
        isFullscreenPodcastPresented: Bool
    ) -> Bool {
        guard isSidebarVisible, hasVideoSurface, hasPendingVideo else { return false }
        return !isFullscreenPodcastPresented
    }
}

// MARK: - PlayerSurfaceOwnership

/// Single-writer rule for the shared WebView's DOM presentation.
///
/// Three hosts (`PersistentPlayerView` in the sidebar, the hidden audio layer, the podcast
/// layer) mount and unmount around the same toggle, and every one of them calls
/// `updateMiniPlayerPresentation` on appearance. Last-writer-wins made the outcome of a
/// toggle depend on view-update ordering: a dying hidden host emitting `expanded:false`
/// after the sidebar applied `expanded:true` tore the extraction down for good (the flags
/// already read "expanded", so nothing ever re-applied). Hence image→video worked only
/// about half the time. An expanded surface always wins ownership; a parking request from
/// a container that does not own the surface is ignored. Pure, so the rule is testable
/// without a window on screen.
enum PlayerSurfaceOwnership {
    /// Whether a presentation request from `owner` may change the DOM presentation.
    ///
    /// - `isExpanded:true` always applies: a surface explicitly wants the video.
    /// - `isExpanded:false` (parking) applies when nobody owns the surface, when the
    ///   requester owns it, or when no surface is active — never by tearing down
    ///   another container's live extraction.
    static func shouldApply(
        isExpanded: Bool,
        owner: AnyObject,
        currentOwner: AnyObject?,
        presentationEnabled: Bool
    ) -> Bool {
        if isExpanded { return true }
        guard let currentOwner else { return true }
        if currentOwner === owner { return true }
        return !presentationEnabled
    }

    /// Whether dismantling `container` releases ownership of the presentation.
    static func shouldReleaseOwner(container: AnyObject, currentOwner: AnyObject?) -> Bool {
        guard let currentOwner else { return false }
        return currentOwner === container
    }

    /// Whether a host may move the shared WebView into its own container.
    ///
    /// The same single-writer rule governs the WebView's *view* hierarchy, not just the DOM
    /// presentation: there is one WebView and one superview, and a host that takes it hides the
    /// picture everywhere else. A parking host (the invisible 1×1 audio layer) is re-mounted for
    /// a single update whenever `isSidebarVideoShowing` briefly reads false — a track change, a
    /// metadata refresh — and taking the WebView then left the sidebar's surface drawing a black
    /// box: the sidebar's representable is not updated when the parker disappears, so nothing
    /// gave the WebView back. A parking host may take it only when no video surface owns the
    /// presentation; an expanded host always may, exactly as it always wins the presentation.
    static func mayHost(
        isExpanded: Bool,
        owner: AnyObject?,
        container: AnyObject,
        presentationEnabled: Bool
    ) -> Bool {
        if isExpanded { return true }
        guard presentationEnabled, let owner else { return true }
        return owner === container
    }
}
