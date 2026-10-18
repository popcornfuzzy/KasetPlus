import AppKit
import SwiftUI

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

    private let logger = DiagnosticsLogger.player

    func makeNSView(context _: Context) -> NSView {
        self.logger.info("PersistentPlayerView.makeNSView for videoId: \(self.videoId ?? "none")")

        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        SingletonPlayerWebView.shared.registerHost(container, isExpanded: self.isExpanded)

        // Get or create the singleton WebView
        let webView = SingletonPlayerWebView.shared.getWebView(
            webKitManager: self.webKitManager,
            playerService: self.playerService
        )

        // Remove from any previous superview and add to this container
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        // Keep the shared WebView in a video-focused presentation when the mini player is visible.
        SingletonPlayerWebView.shared.updateMiniPlayerPresentation(
            owner: container,
            isExpanded: self.isExpanded,
            prefersVideo: self.prefersVideo
        )

        self.loadPageIfNeeded()

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
        SingletonPlayerWebView.shared.registerHost(container, isExpanded: self.isExpanded)

        // Ensure WebView is in this container
        let webView = SingletonPlayerWebView.shared.getWebView(
            webKitManager: self.webKitManager,
            playerService: self.playerService
        )

        if webView.superview !== container {
            self.logger.info("Re-parenting WebView to current container")
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }

        webView.frame = container.bounds

        SingletonPlayerWebView.shared.updateMiniPlayerPresentation(
            owner: container,
            isExpanded: self.isExpanded,
            prefersVideo: self.prefersVideo
        )

        self.loadPageIfNeeded()
    }
}

