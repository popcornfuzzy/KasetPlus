import AppKit
import SwiftUI

// MARK: - PlayerHostView

/// The container a `PersistentPlayerView` gives the shared WebView.
///
/// It reports its own layout because the WebView may not be shown before it has a size:
/// `makeNSView` runs before SwiftUI lays the view out, and hosting the page in a 0×0 view builds
/// its viewport — and the video's own layer — at that size, then resizes both once layout
/// arrives. That is the band of black around the picture right after switching to the video.
final class PlayerHostView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        self.onLayout?()
    }
}

// MARK: - PersistentPlayerView

/// A SwiftUI view that displays the singleton WebView.
/// The WebView is created once and reused for all playback.
///
/// `videoId` is `nil` before anything is played: the layer is hosted from launch so the WebView (and
/// the YouTube Music shell inside it) exists before the user asks for music, and a nil id means this
/// pass is only here for that warm-up.
struct PersistentPlayerView: NSViewRepresentable {
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(PlayerService.self) private var playerService

    let videoId: String?
    let isExpanded: Bool
    let prefersVideo: Bool
    /// Whether this surface is the video's own shape, so the picture fills it rather than being
    /// letterboxed inside it (see `SidebarVideoAspect.Box.matchesVideoShape`).
    var fillsSurface: Bool = false

    private let logger = DiagnosticsLogger.player

    func makeNSView(context _: Context) -> NSView {
        self.logger.info("PersistentPlayerView.makeNSView for videoId: \(self.videoId ?? "none")")

        let container = PlayerHostView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.onLayout = { [weak container] in
            guard let container else { return }
            SingletonPlayerWebView.shared.ensureInHierarchy(container: container, isExpanded: self.isExpanded)
        }
        SingletonPlayerWebView.shared.registerHost(container, isExpanded: self.isExpanded)

        // Get or create the singleton WebView
        let webView = SingletonPlayerWebView.shared.getWebView(
            webKitManager: self.webKitManager,
            playerService: self.playerService
        )

        webView.autoresizingMask = [.width, .height]

        // Claim (or yield) the presentation first: the host that owns the presentation is the
        // host that shows the WebView, and a parking host must not take it from a video surface
        // that owns it (see `SingletonPlayerWebView.ensureInHierarchy`).
        //
        // Keep the shared WebView in a video-focused presentation when the mini player is visible.
        SingletonPlayerWebView.shared.updateMiniPlayerPresentation(
            owner: container,
            isExpanded: self.isExpanded,
            prefersVideo: self.prefersVideo,
            fillsSurface: self.fillsSurface
        )

        SingletonPlayerWebView.shared.ensureInHierarchy(container: container, isExpanded: self.isExpanded)

        self.loadPageIfNeeded()
        self.reportVideoDimensionsIfNeeded()

        return container
    }

    /// Releases DOM-presentation ownership if this container holds it, so the host
    /// mounting next (hidden layer vs. video surface) takes over deterministically.
    /// Without this, toggle order decides whether the video comes back.
    ///
    /// Then unregisters the container, which re-parents the shared WebView to a surviving
    /// host when this one was showing it. Leaving that to the next host does not work: the
    /// sidebar's representable is not updated when the fullscreen podcast overlay closes
    /// (none of its inputs changed), so the WebView would stay orphaned in this container
    /// while the audio kept playing — the black sidebar.
    static func dismantleNSView(_ container: NSView, coordinator _: ()) {
        SingletonPlayerWebView.shared.releasePresentationOwner(container)
        SingletonPlayerWebView.shared.unregisterHost(container)
    }

    /// Gives the WebView its page: the track that is playing, the track that will be played, or the
    /// shell when there is no track at all (see ``PlayerWebViewPreload``).
    ///
    /// A restored session is the case worth naming: it knows its song and its position before anything
    /// is played, so its watch page is loaded early and held silent instead of being loaded from
    /// scratch by the first press of play.
    private func loadPageIfNeeded() {
        guard let videoId = self.videoId else {
            SingletonPlayerWebView.shared.loadShellIfNeeded()
            return
        }

        if self.playerService.shouldAutoloadPendingVideo,
           SingletonPlayerWebView.shared.currentVideoId != videoId
        {
            self.logger.info("Initial load for videoId: \(videoId)")
            SingletonPlayerWebView.shared.loadVideo(videoId: videoId)
            return
        }

        SingletonPlayerWebView.shared.preloadVideo(
            videoId: videoId,
            startAt: self.playerService.deferredResumePosition
        )
    }

    func updateNSView(_ container: NSView, context _: Context) {
        // Keep the host registry current: a container that changes role must be
        // recorded as such, or the next handoff would pick the wrong survivor.
        if let host = container as? PlayerHostView {
            host.onLayout = { [weak container] in
                guard let container else { return }
                SingletonPlayerWebView.shared.ensureInHierarchy(container: container, isExpanded: self.isExpanded)
            }
        }
        SingletonPlayerWebView.shared.registerHost(container, isExpanded: self.isExpanded)

        // Ensure WebView is in this container
        let webView = SingletonPlayerWebView.shared.getWebView(
            webKitManager: self.webKitManager,
            playerService: self.playerService
        )

        // Presentation first, hosting second: the two must agree on one owner, or a hidden layer
        // that is re-mounted for a single update can take the picture away from the surface that
        // is showing it.
        SingletonPlayerWebView.shared.updateMiniPlayerPresentation(
            owner: container,
            isExpanded: self.isExpanded,
            prefersVideo: self.prefersVideo,
            fillsSurface: self.fillsSurface
        )

        SingletonPlayerWebView.shared.ensureInHierarchy(container: container, isExpanded: self.isExpanded)

        // Only a host that actually holds it may size it: writing the frame of a WebView that is
        // living in another container would resize the picture the user is looking at.
        if webView.superview === container {
            webView.frame = container.bounds
        }

        self.loadPageIfNeeded()
        self.reportVideoDimensionsIfNeeded()
    }

    /// Asks the page to describe the picture this surface draws, when the app does not already
    /// know it for the video it is about to show.
    ///
    /// The surface's height *is* that ratio, so a missing one is not cosmetic: the fallback shape
    /// letterboxes the picture, and the black around it is the letterbox. Asking on attach is what
    /// makes the shape known before the first frame is drawn rather than whenever the player's next
    /// state update happens to carry it — and only while it is missing, so the steady state costs
    /// nothing.
    private func reportVideoDimensionsIfNeeded() {
        guard self.prefersVideo else { return }
        let shownVideoId = self.playerService.pendingPlayVideoId ?? self.playerService.currentTrack?.videoId
        guard let shownVideoId, self.playerService.miniPlayerVideoAspectRatioVideoId != shownVideoId else {
            return
        }
        SingletonPlayerWebView.shared.requestVideoDimensions()
    }
}

