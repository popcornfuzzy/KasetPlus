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
