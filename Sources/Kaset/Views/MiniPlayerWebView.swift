import SwiftUI
import WebKit

// MARK: - MiniPlayerWebView

/// A visible WebView that displays the YouTube Music player.
/// This is required because YouTube Music won't initialize the video player
/// without user interaction - autoplay is blocked in hidden WebViews.
/// Uses SingletonPlayerWebView for the actual WebView instance.
struct MiniPlayerWebView: NSViewRepresentable {
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(PlayerService.self) private var playerService

    /// The video ID to play.
    let videoId: String

    /// Callback for player state changes.
    var onStateChange: ((PlayerState) -> Void)?

    /// Callback for metadata updates (title, artist, duration).
    var onMetadataChange: ((String, String, Double) -> Void)?

    enum PlayerState {
        case loading
        case playing
        case paused
        case ended
        case error(String)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onStateChange: self.onStateChange, onMetadataChange: self.onMetadataChange)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true

        // Get or create the singleton WebView
        let webView = SingletonPlayerWebView.shared.getWebView(
            webKitManager: self.webKitManager,
            playerService: self.playerService
        )

        // Remove existing handler if present to avoid duplicates, then add fresh one
        // This handles the case where makeNSView is called multiple times
        let contentController = webView.configuration.userContentController
        contentController.removeScriptMessageHandler(forName: "miniPlayer")
        contentController.add(context.coordinator, name: "miniPlayer")

        // Ensure WebView is in this container
        SingletonPlayerWebView.shared.ensureInHierarchy(container: container, isExpanded: true)

        // Load the video if needed
        SingletonPlayerWebView.shared.loadVideo(videoId: self.videoId)

        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        // Update WebView frame if needed
        SingletonPlayerWebView.shared.ensureInHierarchy(container: container, isExpanded: true)
    }

    static func dismantleNSView(_: NSView, coordinator _: Coordinator) {
        // WebView is managed by SingletonPlayerWebView.shared - it persists
        // Remove the message handler to avoid duplicate handlers
        SingletonPlayerWebView.shared.webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: "miniPlayer")
    }

    // MARK: - Observer Script

    /// Script that observes the YouTube Music player bar and sends updates
    private static var observerScript: String {
        """
        (function() {
            'use strict';

            const bridge = window.webkit.messageHandlers.miniPlayer;

            function log(msg) {
                console.log('[MiniPlayer] ' + msg);
            }

            // Wait for the player bar to appear and observe it
            function waitForPlayerBar() {
                const playerBar = document.querySelector('ytmusic-player-bar');
                if (playerBar) {
                    log('Player bar found, setting up observer');
                    setupObserver(playerBar);
                    return;
                }
                setTimeout(waitForPlayerBar, 500);
            }

            function setupObserver(playerBar) {
                const observer = new MutationObserver(function(mutations) {
                    sendUpdate();
                });

                observer.observe(playerBar, {
                    attributes: true,
                    characterData: true,
                    childList: true,
                    subtree: true,
                    attributeOldValue: true,
                    characterDataOldValue: true
                });

                // Send initial update
                sendUpdate();

                // Also send periodic updates
                setInterval(sendUpdate, 1000);
            }

            function sendUpdate() {
                try {
                    const titleEl = document.querySelector('.ytmusic-player-bar.title');
                    const artistEl = document.querySelector('.ytmusic-player-bar.byline');
                    const progressBar = document.querySelector('#progress-bar');

                    const title = titleEl ? titleEl.textContent : '';
                    const artist = artistEl ? artistEl.textContent : '';
                    const progress = progressBar ? parseInt(progressBar.getAttribute('value') || '0') : 0;
                    const duration = progressBar ? parseInt(progressBar.getAttribute('aria-valuemax') || '0') : 0;

                    // Use video element's paused property for language-agnostic detection
                    // Previously checked button title/aria-label which fails for non-English locales
                    const video = document.querySelector('video');
                    const isPlaying = video ? !video.paused : false;

                    bridge.postMessage({
                        type: 'STATE_UPDATE',
                        title: title,
                        artist: artist,
                        progress: progress,
                        duration: duration,
                        isPlaying: isPlaying
                    });
                } catch (e) {
                    log('Error sending update: ' + e);
                }
            }

            // Start waiting
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', waitForPlayerBar);
            } else {
                waitForPlayerBar();
            }
        })();
        """
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onStateChange: ((PlayerState) -> Void)?
        var onMetadataChange: ((String, String, Double) -> Void)?

        init(
            onStateChange: ((PlayerState) -> Void)?,
            onMetadataChange: ((String, String, Double) -> Void)?
        ) {
            self.onStateChange = onStateChange
            self.onMetadataChange = onMetadataChange
        }

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            // Page loaded
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            self.onStateChange?(.error(error.localizedDescription))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // WebView content process crashed - attempt recovery by reloading
            DiagnosticsLogger.player.error("MiniPlayer WebView content process terminated, attempting reload")
            self.onStateChange?(.error("Player crashed, reloading..."))
            webView.reload()
        }

        func userContentController(
            _: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }

            if type == "STATE_UPDATE" {
                let title = body["title"] as? String ?? ""
                let artist = body["artist"] as? String ?? ""
                let duration = body["duration"] as? Double ?? 0
                let isPlaying = body["isPlaying"] as? Bool ?? false

                if !title.isEmpty {
                    self.onMetadataChange?(title, artist, duration)
                }

                self.onStateChange?(isPlaying ? .playing : .paused)
            }
        }
    }
}

// MARK: - SingletonPlayerWebView

/// Manages a single WebView instance for the entire app lifetime.
/// This ensures there's only ever ONE WebView playing audio.
///
/// Extensions provide:
/// - Playback controls (SingletonPlayerWebView+PlaybackControls.swift)
/// - Observer script (SingletonPlayerWebView+ObserverScript.swift)
@MainActor
final class SingletonPlayerWebView {
    static let shared = SingletonPlayerWebView()

    private(set) var webView: WKWebView?
    var currentVideoId: String?
    var coordinator: Coordinator?
    let logger = DiagnosticsLogger.player

    /// What the page in the WebView is for. A page that is not being played from must not report, and
    /// a page loaded early must not be replaced (see ``PlayerWebViewPage``).
    private(set) var page: PlayerWebViewPage = .empty

    /// Progress observation for the page load in flight, replaced with each WebView.
    private var estimatedProgressObservation: NSKeyValueObservation?

    /// The YouTube Music shell: the cheapest page that warms the app, and one that carries no track.
    /// It is held silent like a preloaded track — a shell left to itself could play something the app
    /// is not tracking.
    private static var shellURL: URL? {
        Self.url(path: "/", queryItems: [Self.preloadHoldQueryItem])
    }

    /// Name of the query flag that marks a page Kaset loads only to have ready. The page's own gate
    /// reads it (see ``preloadGateScript``) so a warm page cannot make a sound before the user asks.
    static let preloadQueryFlagName = "kaset_preload"

    /// Value of the query flag that marks a page loaded only to be ready.
    static let preloadQueryFlagValue = "1"

    /// The query item that marks a page as loaded only to be ready.
    private static var preloadHoldQueryItem: URLQueryItem {
        URLQueryItem(name: Self.preloadQueryFlagName, value: Self.preloadQueryFlagValue)
    }

    /// Builds a YouTube Music URL.
    private static func url(path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "music.youtube.com"
        components.path = path
        components.queryItems = queryItems
        return components.url
    }

    /// A watch URL for the shared WebView.
    ///
    /// - Parameter startAt: position the player should begin from, passed as YouTube's own `t`
    ///   parameter. A restored session resumes from where it left off, and having the page *start*
    ///   there is what makes the resume instant instead of a seek after the fact.
    /// - Parameter holdsSilent: marks the page as one loaded only to be ready, so its own autoplay is
    ///   held until Kaset or the user asks for sound.
    static func watchURL(videoId: String, startAt: TimeInterval? = nil, holdsSilent: Bool = false) -> URL? {
        var queryItems = [URLQueryItem(name: "v", value: videoId)]

        if let startAt, startAt >= 1 {
            queryItems.append(URLQueryItem(name: "t", value: "\(Int(startAt.rounded(.down)))s"))
        }
        if holdsSilent {
            queryItems.append(Self.preloadHoldQueryItem)
        }

        return Self.url(path: "/watch", queryItems: queryItems)
    }

    /// Whether this URL is the shell rather than a watch page.
    static func isShellURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.host() == "music.youtube.com" && (url.path().isEmpty || url.path() == "/")
    }

    /// How `loadVideo` behaves when Swift already tracks a `videoId` (repeat-one vs queue drift recovery).
    enum VideoLoadStrategy: Equatable {
        /// Skip navigation when `videoId` matches `currentVideoId`.
        case standard
        /// Same `videoId` as tracked: `seek(0)` + play only (fast). Different id: full watch URL load.
        case preferInPlaceWhenSameVideoId
        /// Same `videoId` as tracked: full `webView.load` (DOM out of sync with Swift). Different id: full load.
        case forceFullPageWhenSameVideoId
    }

    private var mediaControlUsesNextPrev: Bool
    private var miniPlayerPresentationEnabled = false
    private var miniPlayerPrefersVideo = false
    /// Whether the surface that owns the presentation is the video's own shape, so the picture
    /// fills it instead of being letterboxed inside it.
    private var miniPlayerFillsSurface = false
    /// Container view that owns the DOM presentation. Weak: a dismantled host must
    /// never pin its view alive, and a dead owner simply means "unowned".
    /// See ``PlayerSurfaceOwnership`` for the single-writer rule.
    private weak var presentationOwner: NSView?

    /// Containers the WebView can be shown in, oldest first. The WebView is never
    /// left behind when one of them is dismantled — it moves to the best survivor
    /// (see ``PlayerWebViewHosting``).
    private var hosts: [PlayerHost] = []

    /// A registered container. A class because `weak` storage is not allowed in a
    /// struct, and a dismantled host must never be kept alive by this list.
    private final class PlayerHost {
        weak var container: NSView?
        let isExpanded: Bool

        init(container: NSView, isExpanded: Bool) {
            self.container = container
            self.isExpanded = isExpanded
        }
    }

    private init() {
        self.mediaControlUsesNextPrev = SettingsManager.shared.mediaControlStyle == .nextPreviousTrack
    }

    /// Get or create the singleton WebView.
    func getWebView(
        webKitManager: WebKitManager,
        playerService: PlayerService
    ) -> WKWebView {
        if let existing = webView {
            return existing
        }

        self.logger.info("Creating singleton WebView")

        // Create coordinator
        self.coordinator = Coordinator(playerService: playerService)

        let configuration = webKitManager.createWebViewConfiguration()

        // Add script message handler
        configuration.userContentController.add(self.coordinator!, name: "singletonPlayer")

        // Note: We do NOT inject a static volume init script here because the volume
        // may change between WebView creation and page loads. Instead, we:
        // 1. Set __kasetTargetVolume in loadVideo() before loading a new page
        // 2. Update it in didFinish after each page load completes
        // This ensures we always use the CURRENT volume, not a stale value.

        // Keep the page preference in sync before any page script reads localStorage.
        let mediaControlBootstrapScript = WKUserScript(
            source: self.mediaControlBootstrapScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(mediaControlBootstrapScript)

        let adBlockingFlagScript = WKUserScript(
            source: "window.__kasetSafeAdBlockingEnabled = \(SettingsManager.shared.safeAdBlockingEnabled ? "true" : "false");",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(adBlockingFlagScript)

        if SettingsManager.shared.safeAdBlockingEnabled {
            // Strip ad payload fields from player responses before YouTube Music consumes them.
            let adPruningScript = WKUserScript(
                source: Self.adPruningScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            configuration.userContentController.addUserScript(adPruningScript)
        }

        // Inject mediaSession override at document end without allowing duplicate RAF loops.
        let mediaOverrideScript = WKUserScript(
            source: Self.mediaControlOverrideScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(mediaOverrideScript)

        // Inject observer script (at document end)
        let script = WKUserScript(
            source: Self.observerScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(script)

        // The in-page playback bridge: what lets a track change stay inside the open document instead
        // of costing a page load. Idempotent, feature-detected and silent when the page's player API
        // is not there; see `SingletonPlayerWebView+PagePlayback`.
        let pagePlaybackBridge = WKUserScript(
            source: Self.pagePlaybackBridgeScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(pagePlaybackBridge)

        // The preload gate, ahead of everything: a page Kaset loads only to have ready must not be
        // able to make a sound before the user asks for it. See `preloadGateScript`.
        let preloadGateScript = WKUserScript(
            source: Self.preloadGateScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(preloadGateScript)

        // A document loaded while the video surface is showing covers itself at parse time, so
        // the surface never paints the page's own player chrome before the presentation is
        // applied to the new document. See `presentationCoverScript`.
        let presentationCoverScript = WKUserScript(
            source: Self.presentationCoverScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(presentationCoverScript)

        let newWebView = WKWebView(frame: .zero, configuration: configuration)
        newWebView.navigationDelegate = self.coordinator
        newWebView.customUserAgent = WebKitManager.userAgent

        #if DEBUG
            newWebView.isInspectable = true
        #endif

        // The page load's own estimate, which is what the player bar's loading strip fills from. It
        // is the only measurable wait the player has, so it is read from WebKit rather than
        // guessed at: nothing about a YouTube Music page load is observable from the outside.
        self.estimatedProgressObservation = newWebView.observe(\.estimatedProgress, options: [.new]) { webView, _ in
            MainActor.assumeIsolated {
                playerService.updateWebViewPageLoadProgress(webView.estimatedProgress)
            }
        }

        self.webView = newWebView
        return newWebView
    }

    /// Loads the YouTube Music shell into a WebView that has nothing in it, so the first play of a
    /// session does not have to wait for the app to boot (see ``PlayerWebViewPreload``).
    ///
    /// Safe to call on every layout pass: it does nothing once a page has been navigated to.
    func loadShellIfNeeded() {
        guard let webView,
              PlayerWebViewPreload.canLoadShell(currentVideoId: self.currentVideoId, page: self.page),
              let shellURL = Self.shellURL
        else { return }

        self.page = .shell
        self.logger.info("Preloading the YouTube Music shell")
        webView.load(URLRequest(url: shellURL))
    }

    /// Loads a track's watch page early, held silent, so the first press of play starts the song
    /// instead of loading it (see ``PlayerWebViewPreload``).
    ///
    /// - Parameter startAt: position to resume from, for a restored session that has not been resumed
    ///   yet. Passing it in the URL means the page is already in place when play is pressed.
    ///
    /// Safe to call on every layout pass: it does nothing once a watch page is up.
    func preloadVideo(videoId: String, startAt: TimeInterval? = nil) {
        guard let webView,
              PlayerWebViewPreload.canLoadPreload(currentVideoId: self.currentVideoId, page: self.page),
              let url = Self.watchURL(videoId: videoId, startAt: startAt, holdsSilent: true)
        else { return }

        self.logger.info("Preloading watch page for \(videoId)")
        self.currentVideoId = videoId
        self.page = .preloaded
        webView.load(URLRequest(url: url))
    }

    /// Lifts the preload hold, so the page may make sound again.
    ///
    /// Called by every control Kaset drives. The page's own player was told it started playing when
    /// the hold swallowed its autoplay, so the gate also brings the page back in line with reality:
    /// without that, the first play/pause click in a preloaded page would be a *pause*.
    func releasePreloadHold() {
        guard self.page == .preloaded else { return }
        self.page = .playback
        self.logger.info("Releasing the preload hold")
        self.webView?.evaluateJavaScript(
            "window.__kasetPreloadStandDown && window.__kasetPreloadStandDown();",
            completionHandler: nil
        )
    }

    /// Hands a page the user can now see back to them.
    ///
    /// The mini player *is* the page's own controls, so a visible page is no longer a placeholder and
    /// no longer held: whatever it plays, the user asked for it there and the app tracks it like any
    /// other page. Nothing else makes a silent page authoritative.
    func handOverToUser() {
        guard self.page.isSilent else { return }
        self.logger.info("Handing the visible page over to the user")
        self.releasePreloadHold()
        self.page = .playback
    }

    /// Whether the page in the WebView has finished loading.
    ///
    /// A preload still in flight is not ready to be asked to play: its own scripts have not run yet.
    var isPageReady: Bool {
        !(self.webView?.isLoading ?? true)
    }

    /// Whether a page for `videoId` is up and usable for playback.
    ///
    /// Kaset's own watch page for the track qualifies, and so does a finished preload of it — that is
    /// the case the preload exists for, and playing it needs no navigation. A preload still loading
    /// does not: the track then takes the ordinary path, which navigates properly rather than asking a
    /// page that is not there yet to play.
    func canPlay(videoId: String) -> Bool {
        guard self.currentVideoId == videoId else { return false }
        guard self.page == .preloaded else { return true }
        return self.isPageReady
    }

    /// Ensures the WebView is in the given container's view hierarchy, when that container may
    /// show it.
    ///
    /// `isExpanded` is the host's own intent. A parking host may only take the WebView while no
    /// video surface owns the presentation (see ``PlayerSurfaceOwnership/mayHost``): the hidden
    /// audio layer is re-mounted for a single update when the sidebar video's state flickers, and
    /// taking the WebView then left the sidebar surface black until something else happened to
    /// move it back.
    func ensureInHierarchy(container: NSView, isExpanded: Bool) {
        guard let webView, webView.superview !== container else { return }

        // A host is laid out *after* SwiftUI creates it. Showing the page in a 0×0 view builds its
        // viewport — and the video's layer — at that size and resizes both once layout arrives,
        // which paints the picture in a box that is not the surface yet (the black band around it
        // right after switching to the video). The host calls back on layout.
        guard container.bounds.width >= 1, container.bounds.height >= 1 else { return }

        guard PlayerSurfaceOwnership.mayHost(
            isExpanded: isExpanded,
            owner: self.presentationOwner,
            container: container,
            presentationEnabled: self.miniPlayerPresentationEnabled
        ) else {
            self.logger.info("Parking host asked for the WebView while a video surface owns it; ignoring")
            return
        }

        webView.removeFromSuperview()
        container.addSubview(webView)

        // Use autoresizing to match container size.
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
    }

    /// Registers `container` as a place the shared WebView may be shown.
    ///
    /// Every host does this as it mounts (and on update, so a host that changes role is
    /// recorded correctly). Registration is what lets a dying host hand the WebView back
    /// instead of orphaning it: SwiftUI gives a host that is still mounted no update when
    /// another host disappears, so that host cannot notice on its own.
    func registerHost(_ container: NSView, isExpanded: Bool) {
        self.hosts.removeAll { $0.container == nil || $0.container === container }
        self.hosts.append(PlayerHost(container: container, isExpanded: isExpanded))
    }

    /// Unregisters a dismantling host and, if the WebView was living in its container,
    /// hands it to a surviving host immediately.
    ///
    /// This is the podcast-fullscreen handoff: the overlay's container is dismantled when
    /// the experience closes, and the sidebar's representable is not updated because none
    /// of its inputs changed. Without this the WebView ends up with `window == nil` and
    /// `superview == nil` — audio playing with nothing to draw the picture in.
    func unregisterHost(_ container: NSView) {
        let heldWebView = self.webView?.superview === container
        self.hosts.removeAll { $0.container == nil || $0.container === container }
        guard heldWebView else { return }
        self.rehomeWebViewAfterHostRemoval()
    }

    /// Moves the WebView to the best surviving host, or leaves it alone when none is left
    /// (a host mounting next puts it in the hierarchy itself).
    private func rehomeWebViewAfterHostRemoval() {
        guard let webView else { return }

        let candidates = self.hosts.map {
            PlayerWebViewHosting.Candidate(isExpanded: $0.isExpanded, isInWindow: $0.container?.window != nil)
        }
        guard let index = PlayerWebViewHosting.preferredHost(candidates),
              let target = self.hosts[index].container
        else {
            self.logger.info("Player host removed; no surviving host to hand the WebView to yet")
            return
        }

        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = target.bounds
        webView.autoresizingMask = [.width, .height]
        target.addSubview(webView)

        let message = "Player host removed; WebView moved to a surviving host"
            + " (expanded: \(self.hosts[index].isExpanded), inWindow: \(target.window != nil),"
            + " size: \(Int(target.bounds.width))x\(Int(target.bounds.height)))"
        self.logger.info("\(message, privacy: .public)")
    }

    /// Releases DOM-presentation ownership when `container` holds it (called from the
    /// host's `dismantleNSView`), so a parking host mounting afterwards takes over
    /// deterministically instead of racing a stale owner.
    func releasePresentationOwner(_ container: NSView) {
        if PlayerSurfaceOwnership.shouldReleaseOwner(container: container, currentOwner: self.presentationOwner) {
            self.presentationOwner = nil
        }
    }

    /// Updates the DOM presentation for the mini player overlay.
    /// When expanded, the page chrome is hidden and the video surface is prioritized.
    ///
    /// `owner` is the requesting host's container. A parking (`isExpanded:false`)
    /// request from a container that does not own an active surface is ignored:
    /// during a toggle both the dying hidden host and the new video host emit in the
    /// same pass, and letting the parker win tore down extractions that never came
    /// back (see ``PlayerSurfaceOwnership``).
    func updateMiniPlayerPresentation(
        owner: NSView,
        isExpanded: Bool,
        prefersVideo: Bool,
        fillsSurface: Bool = false
    ) {
        guard PlayerSurfaceOwnership.shouldApply(
            isExpanded: isExpanded,
            owner: owner,
            currentOwner: self.presentationOwner,
            presentationEnabled: self.miniPlayerPresentationEnabled
        ) else {
            self.logger.debug("Ignoring parking presentation from non-owning host while video surface is active")
            return
        }
        self.presentationOwner = owner

        let previousIsExpanded = self.miniPlayerPresentationEnabled
        let previousPrefersVideo = self.miniPlayerPrefersVideo
        let previousFillsSurface = self.miniPlayerFillsSurface

        self.miniPlayerPresentationEnabled = isExpanded
        self.miniPlayerPrefersVideo = prefersVideo
        self.miniPlayerFillsSurface = fillsSurface

        // A page the user can see is the page's own controls: if the mini player has just been
        // revealed, a silent page stops being silent and stops being treated as a placeholder.
        if isExpanded, !previousIsExpanded {
            self.handOverToUser()
        }

        // Ignore pure size changes while staying expanded; the container now scales with 100% sizing.
        guard previousIsExpanded != isExpanded
            || previousPrefersVideo != prefersVideo
            || previousFillsSurface != fillsSurface
        else {
            return
        }

        self.applyMiniPlayerPresentationScript()
    }

    /// Re-applies mini player DOM presentation after navigation finishes.
    func reapplyMiniPlayerPresentationIfNeeded() {
        self.applyMiniPlayerPresentationScript()
    }

    /// The sessionStorage key the presentation state is remembered under, so a document can
    /// cover itself before its first paint (see ``presentationCoverScript``).
    static let presentationStorageKey = "kaset-mini-player-presentation"

    /// Script that hides a page loaded while the video surface is showing.
    ///
    /// A navigation replaces the whole document, taking the presentation's container and
    /// blackout with it. Until the presentation script runs again (after the load finishes) the
    /// surface would draw the raw YouTube Music page — the flash of its player chrome that the
    /// sidebar used to show on some track changes. The state is kept in `sessionStorage`, which
    /// survives a same-origin navigation, so the next document can cover itself at parse time
    /// and uncover only once there is a picture (the presentation script removes the cover).
    static var presentationCoverScript: String {
        """
        (function() {
            try {
                if (sessionStorage.getItem('\(Self.presentationStorageKey)') !== '1') { return; }
            } catch (error) {
                return;
            }
            const style = document.createElement('style');
            style.id = 'kaset-presentation-cover';
            style.textContent = 'html { background: #000 !important; }'
                + ' body { background: #000 !important; visibility: hidden !important; }';
            (document.head || document.documentElement).appendChild(style);
        })();
        """
    }

    /// Asks the page for the intrinsic size of the video it is showing.
    ///
    /// The surface is sized from that ratio, and the presentation is only re-applied when it
    /// changes — so a surface that attaches before the video has decoded a frame would otherwise
    /// keep the 16:9 fallback (and the letterboxed picture that goes with it) until the next
    /// `STATE_UPDATE` happens to arrive.
    func requestVideoDimensions() {
        guard let webView else { return }
        webView.evaluateJavaScript(Self.videoDimensionsRequestScript()) { [weak self] _, error in
            if let error {
                self?.logger.debug("Failed to request video dimensions: \(error.localizedDescription)")
            }
        }
    }

    /// Script asking the page to report the size of the video it is drawing.
    ///
    /// Pure construction, like ``miniPlayerPresentationScript(isExpanded:prefersVideo:fillsSurface:)``,
    /// so the exact snippet the app injects can be asserted without a WebView.
    static func videoDimensionsRequestScript() -> String {
        """
            (function() {
                const bridge = window.webkit.messageHandlers.singletonPlayer;
                if (!bridge) { return; }

                // The picture's shape belongs to the element that is playing; a stale node left
                // behind by a player re-render describes a video that is not on screen.
                const videos = document.querySelectorAll('video');
                let video = null;
                for (let index = 0; index < videos.length; index++) {
                    const candidate = videos[index];
                    if (!(candidate.videoWidth > 0) || !(candidate.videoHeight > 0)) continue;
                    if (!candidate.paused) { video = candidate; break; }
                    if (!video) video = candidate;
                }
                if (!video) { return; }

                bridge.postMessage({
                    type: 'VIDEO_DIMENSIONS',
                    width: video.videoWidth,
                    height: video.videoHeight
                });
            })();
        """
    }

    /// Builds the DOM presentation script for a presentation state.
    ///
    /// Pure construction (no WebView touch), so the exact script the app injects can be
    /// driven against a mock page in tests — that is how the podcast-exit handoff is
    /// reproduced without the app GUI.
    static func miniPlayerPresentationScript(
        isExpanded: Bool,
        prefersVideo: Bool,
        fillsSurface: Bool = false
    ) -> String {
        let isExpandedLiteral = isExpanded ? "true" : "false"
        let prefersVideoLiteral = prefersVideo ? "true" : "false"
        let objectFit = fillsSurface ? "cover" : "contain"

        return """
            (function() {
                const enabled = \(isExpandedLiteral);
                const prefersVideo = \(prefersVideoLiteral);

                const styleId = 'kaset-mini-player-video-style';
                const containerId = 'kaset-video-container';
                const blackoutId = 'kaset-video-blackout';
                const coverId = 'kaset-presentation-cover';
                const storageKey = '\(Self.presentationStorageKey)';
                const timerIdKey = '__kasetMiniPlayerVideoTimer';
                const observerKey = '__kasetMiniPlayerVideoObserver';
                const shownVideoKey = '__kasetMiniPlayerShownVideo';
                const healFrameKey = '__kasetMiniPlayerHealFrame';

                window.__kasetMiniPlayerPresentationEnabled = enabled;
                window.__kasetMiniPlayerPrefersVideo = prefersVideo;

                // Remembered for the next document: a page loaded while the surface is
                // showing covers itself before its first paint (see `presentationCoverScript`).
                try {
                    sessionStorage.setItem(storageKey, enabled ? '1' : '0');
                } catch (error) {}

                function clearTabTimer() {
                    if (window[timerIdKey]) {
                        clearInterval(window[timerIdKey]);
                        window[timerIdKey] = null;
                    }
                }

                function removeCover() {
                    const cover = document.getElementById(coverId);
                    if (cover) cover.remove();
                }

                // The video the page is actually showing.
                //
                // `document.querySelector('video')` is not enough: after YouTube re-renders
                // its player it can leave the element we took behind while a new one plays the
                // sound. A container holding that dead node is a black box that never heals,
                // because the old liveness check only asked whether *some* video was still in
                // the container. The picture must always be the element that is playing.
                function currentVideo() {
                    const videos = document.querySelectorAll('video');
                    let framed = null;
                    for (let index = 0; index < videos.length; index++) {
                        const video = videos[index];
                        const hasFrame = (video.readyState || 0) >= 2 || (video.videoWidth || 0) > 0;
                        if (!hasFrame) continue;
                        if (!video.paused) return video;
                        if (!framed) framed = video;
                    }
                    return framed;
                }

                function containerShowsCurrentVideo() {
                    const container = document.getElementById(containerId);
                    const shown = window[shownVideoKey];
                    if (!container || !shown || shown.parentElement !== container) return false;
                    if (container.firstElementChild !== shown) return false;
                    return currentVideo() === shown;
                }

                // Tells the app the picture's own shape as soon as the surface draws it. The
                // surface is *sized* from that ratio, so learning it here — including while the
                // video is only playing in the invisible layer — means the box is already the
                // picture's shape when the user switches to it. The alternative, asking after the
                // switch, leaves the surface as the 16:9 fallback for the first frames, and a
                // picture that is not 16:9 is letterboxed inside it: black bars around the video
                // right after switching to it.
                function reportPictureShape(video) {
                    const width = video.videoWidth || 0;
                    const height = video.videoHeight || 0;
                    if (width <= 0 || height <= 0) return;
                    const shape = width + 'x' + height;
                    if (window.__kasetReportedShape === shape) return;
                    window.__kasetReportedShape = shape;

                    const bridge = window.webkit && window.webkit.messageHandlers
                        ? window.webkit.messageHandlers.singletonPlayer
                        : null;
                    if (!bridge) return;
                    bridge.postMessage({ type: 'VIDEO_DIMENSIONS', width: width, height: height });
                }

                function showCurrentVideo() {
                    const video = currentVideo();
                    if (!video) return false;

                    const container = ensureContainer();

                    // The surface has exactly one picture. Anything else in the container is a
                    // node the page has stopped using, and a dead video left underneath can
                    // still paint at its own size over the picture.
                    const stale = container.querySelectorAll('video');
                    for (let index = 0; index < stale.length; index++) {
                        if (stale[index] !== video) stale[index].remove();
                    }

                    if (video.parentElement !== container) {
                        container.appendChild(video);
                    }
                    if (video.controls) video.controls = false;
                    window[shownVideoKey] = video;
                    reportPictureShape(video);

                    // Nothing of the page belongs in a surface that has a picture.
                    removeBlackout();
                    removeCover();
                    return true;
                }

                // Healing is scheduled as a microtask: it runs as soon as the task that broke
                // the picture ends and always *before* the browser paints, so a surface cannot
                // show a frame of an empty box. The old one-second poll could show one for a
                // whole second, and never healed a container that held a dead node at all.
                //
                // A microtask also costs one check per mutation batch rather than one per
                // mutation: YouTube's player mutates its DOM constantly (progress, chapters,
                // overlays) and healing has to stay cheap.
                function scheduleHeal() {
                    if (window[healFrameKey]) return;
                    window[healFrameKey] = true;
                    Promise.resolve().then(function() {
                        window[healFrameKey] = false;
                        if (!containerShowsCurrentVideo()) {
                            showCurrentVideo();
                        }
                    });
                }

                // Watches the page for the two things that break the picture:
                // the video being taken back out of the container by a player re-render, and a
                // replacement element appearing next to the one we hold.
                //
                // It runs in every presentation state: parking is soft standby that keeps the
                // DOM (the parked host is always the invisible 1x1 layer, so restoring the page
                // is never visible), which is what makes host handoffs instant.
                //
                // Healing never clicks the video tab. A click is a page mutation that can
                // navigate; tab selection is a one-shot intent owned by `startTabAttempts`.
                function ensureHealing() {
                    if (window[observerKey]) return;

                    const observer = new MutationObserver(function() {
                        if (containerShowsCurrentVideo()) return;
                        scheduleHeal();
                    });
                    observer.observe(document.documentElement, { childList: true, subtree: true });
                    window[observerKey] = observer;

                    // A video extracted before it had a frame becomes the picture as soon as it
                    // decodes one — no DOM change is involved, so the observer would never see it.
                    document.addEventListener('loadeddata', scheduleHeal, true);
                    document.addEventListener('playing', scheduleHeal, true);

                    // Safety net for a page that defeats both of the above (a document element
                    // replaced under the observer, a player that swaps its video without a
                    // mutation we witness). Nothing else can heal those, and a surface in that
                    // state is already not the picture the user asked for.
                    setInterval(function() {
                        if (!containerShowsCurrentVideo()) {
                            showCurrentVideo();
                        }
                    }, 2000);
                }

                // The page's own video may still be switched away from Video: retried briefly
                // while the player builds, never after that (see `ensureVideoTabSelected`).
                function startTabAttempts() {
                    if (!window.__kasetMiniPlayerPrefersVideo) return;
                    clearTabTimer();
                    let attempts = 0;
                    window[timerIdKey] = setInterval(function() {
                        if (!window.__kasetMiniPlayerPresentationEnabled) {
                            clearTabTimer();
                            return;
                        }
                        attempts += 1;
                        ensureVideoTabSelected();
                        if (window.__kasetVideoTabClicked || attempts >= 24) {
                            clearTabTimer();
                        }
                    }, 250);
                }

                function ensureStyle() {
                    let style = document.getElementById(styleId);
                    if (!style) {
                        style = document.createElement('style');
                        style.id = styleId;
                        (document.head || document.documentElement).appendChild(style);
                    }

                    style.textContent = `
                        html, body, ytmusic-app, #layout, #content, #contents {
                            background: #000 !important;
                            overflow: hidden !important;
                            pointer-events: none !important;
                            cursor: default !important;
                        }

                        *, *::before, *::after {
                            cursor: default !important;
                        }

                        ytmusic-nav-bar,
                        ytmusic-player-bar,
                        ytmusic-guide-renderer,
                        tp-yt-app-drawer,
                        ytmusic-notification-action-renderer,
                        ytmusic-player-page #tabs,
                        ytmusic-player-page #side-panel,
                        .ytp-chrome-top,
                        .ytp-chrome-bottom,
                        .ytp-gradient-top,
                        .ytp-gradient-bottom,
                        .ytp-cards-button,
                        .ytp-endscreen-content,
                        .ytp-ce-element,
                        .ytmusic-player-page-player-controls {
                            display: none !important;
                        }

                        #${containerId} {
                            position: fixed !important;
                            inset: 0 !important;
                            width: 100% !important;
                            height: 100% !important;
                            background: #000 !important;
                            z-index: 2147483646 !important;
                            overflow: hidden !important;
                            pointer-events: none !important;
                        }

                        #${containerId} video {
                            position: absolute !important;
                            inset: 0 !important;
                            width: 100% !important;
                            height: 100% !important;
                            max-width: none !important;
                            max-height: none !important;
                            margin: 0 !important;
                            transform: none !important;
                            object-fit: \(objectFit) !important;
                            background: #000 !important;
                            pointer-events: none !important;
                        }
                    `;
                }

                function ensureContainer() {
                    let container = document.getElementById(containerId);
                    if (!container) {
                        container = document.createElement('div');
                        container.id = containerId;
                        (document.body || document.documentElement).appendChild(container);
                    }
                    return container;
                }

                function ensureBlackout() {
                    let blackout = document.getElementById(blackoutId);
                    if (!blackout) {
                        blackout = document.createElement('div');
                        blackout.id = blackoutId;
                        blackout.style.position = 'fixed';
                        blackout.style.inset = '0';
                        blackout.style.background = '#000';
                        blackout.style.zIndex = '2147483645';
                        blackout.style.pointerEvents = 'none';
                        (document.body || document.documentElement).appendChild(blackout);
                    }
                    return blackout;
                }

                function removeBlackout() {
                    const blackout = document.getElementById(blackoutId);
                    if (blackout) blackout.remove();
                }

                function findVideoToggle() {
                    const controls = Array.from(
                        document.querySelectorAll('button, tp-yt-paper-button, [role="button"], [role="tab"]')
                    );
                    return controls.find((element) => {
                        const text = (element.textContent || element.innerText || '').trim().toLowerCase();
                        const label = (element.getAttribute('aria-label') || '').trim().toLowerCase();
                        return text === 'video'
                            || text === 'musikvideo'
                            || text === 'music video'
                            || label === 'video'
                            || label === 'music video';
                    });
                }

                function ensureVideoTabSelected() {
                    if (!window.__kasetMiniPlayerPrefersVideo) return;

                    const button = findVideoToggle();
                    if (!button) return;

                    const isSelected = button.getAttribute('aria-selected') === 'true'
                        || button.getAttribute('aria-pressed') === 'true'
                        || button.classList.contains('selected')
                        || button.classList.contains('is-selected');

                    if (isSelected) return;

                    // One click per document. Re-applying the presentation (a learned ratio, a
                    // host handoff, a finished page load) must never click again: the click
                    // restarts the player's video, and on a control that is a toggle rather than
                    // a tab a second click switches the picture away from the surface.
                    if (window.__kasetVideoTabClicked) return;
                    window.__kasetVideoTabClicked = true;
                    button.click();
                }

                // Parking is soft standby, never a teardown: the parked host is always the
                // invisible 1x1 layer, so restoring the page is never visible — it only
                // destroys the extraction the next expanded host must then rebuild
                // asynchronously. That teardown/re-extract race is what left the sidebar
                // black after leaving podcast fullscreen (re-extract missing a swapped
                // element, style re-applied over an empty container) and flashed the
                // page's own controls in between. The DOM stays as it is, and healing keeps it.
                if (!enabled) {
                    clearTabTimer();
                    removeBlackout();
                    removeCover();
                    ensureHealing();
                    scheduleHeal();
                    return;
                }

                ensureStyle();
                ensureBlackout();
                ensureHealing();
                startTabAttempts();

                // The picture and the page's own chrome never share the surface: the blackout
                // stays up (and the next document covers itself, see `presentationCoverScript`)
                // until there is a video to draw in it — `showCurrentVideo` is what uncovers.
                showCurrentVideo();
            })();
        """
    }

    private func applyMiniPlayerPresentationScript() {
        guard let webView else { return }

        let script = Self.miniPlayerPresentationScript(
            isExpanded: self.miniPlayerPresentationEnabled,
            prefersVideo: self.miniPlayerPrefersVideo,
            fillsSurface: self.miniPlayerFillsSurface
        )
        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                self?.logger.debug("Failed to apply mini player presentation script: \(error.localizedDescription)")
            }
        }
    }

    /// Starts high frequency polling for synced lyrics
    func startLyricsPoll() {
        self.webView?.evaluateJavaScript("if (window.startLyricsPoll) { window.startLyricsPoll(); }")
    }

    func sendCurrentLyricsTime() {
        self.webView?.evaluateJavaScript("if (window.sendLyricsTime) { window.sendLyricsTime(); }")
    }

    /// Stops high frequency polling for synced lyrics
    func stopLyricsPoll() {
        self.webView?.evaluateJavaScript("if (window.stopLyricsPoll) { window.stopLyricsPoll(); }")
    }

    /// Updates runtime ad-blocking flag inside the persistent WebView without requiring a reload.
    func setSafeAdBlockingEnabled(_ enabled: Bool) {
        self.webView?.evaluateJavaScript("window.__kasetSafeAdBlockingEnabled = \(enabled ? "true" : "false");")
    }

    /// Test hook: recorded whenever a page load is requested, before anything else.
    /// Lets scripted-observation tests prove which metadata patterns trigger a page
    /// reload (the black-video mechanism) without a live page.
    var onPageLoadRequestForTests: ((String, VideoLoadStrategy) -> Void)?

    /// Load a video, stopping any currently playing audio first.
    ///
    /// Note: Full page navigation destroys the video element; same-id restarts use ``restartInPlaceFromBeginning()`` when possible.
    func loadVideo(videoId: String, strategy: VideoLoadStrategy = .standard) {
        self.onPageLoadRequestForTests?(videoId, strategy)
        guard let webView else {
            self.logger.error("loadVideo called but webView is nil")
            return
        }

        let previousVideoId = self.currentVideoId

        switch strategy {
        case .standard:
            if videoId == previousVideoId {
                // That page may be the preload for this very track, which is already where the
                // navigation would have gone. It only has to be let go of and started, exactly as a
                // fresh page would have started itself — and the hold *must* be lifted here, because
                // this path returns before any control could ask for it, leaving the track silent.
                if self.page == .preloaded, self.isPageReady {
                    self.logger.info("Using the preloaded page for \(videoId)")
                    self.releasePreloadHold()
                    self.play()
                    return
                }

                // A preload that has not finished is not ready to play from, and the hold it carries
                // cannot be lifted into a document that does not exist yet: the track is loaded
                // properly below instead, which cancels the held load and plays the ordinary way.
                if self.page == .preloaded {
                    self.logger.info("Preload for \(videoId) is still loading; loading it for playback")
                } else {
                    self.logger.debug("Video \(videoId) already loaded, skipping")
                    return
                }
            }
        case .preferInPlaceWhenSameVideoId:
            if videoId == previousVideoId {
                self.logger.debug("In-place restart for \(videoId) (same id — avoid full page reload)")
                self.restartInPlaceFromBeginning()
                return
            }
        case .forceFullPageWhenSameVideoId:
            if videoId == previousVideoId {
                self.logger.info("Force full navigation for \(videoId) (DOM/WebView resync)")
            }
        }

        if videoId != previousVideoId {
            self.logger.info("Loading video: \(videoId) (was: \(previousVideoId ?? "none"))")
        }

        // A preloaded page is held silent on purpose. Playback Kaset is driving must not be: the page
        // would load the track and swallow its own play calls, leaving a track that looks started and
        // makes no sound. The hold is lifted before the page's state is overwritten below.
        if self.page == .preloaded {
            self.releasePreloadHold()
        }

        // Update currentVideoId immediately to prevent duplicate loads
        self.currentVideoId = videoId
        // A watch page is a playback page: from here the page's observations are the app's own.
        self.page = .playback

        // Fast path: the page swaps the track inside the open document, which keeps the player, the
        // DRM session and the player bar where they are. A resync strategy is deliberately excluded —
        // that path exists to reload the document.
        if strategy == .standard, self.canSwapTrackInPage {
            let playerService = self.coordinator?.playerService
            self.logger.info("Asking the page's player for \(videoId)")
            playerService?.noteInPagePlayAttempt(videoId: videoId)
            self.playInPage(videoId: videoId) { [weak self] status in
                guard let self, self.currentVideoId == videoId else { return }
                playerService?.updatePagePlaybackCapability(status)

                guard WebPagePlaybackStatus.succeeded(status) else {
                    self.logger.info("The page declined \(videoId) (\(status)); loading its watch page")
                    self.loadWatchPage(videoId: videoId)
                    return
                }

                // The page answering only means it accepted the command; check that it took it.
                playerService?.beginPageSettleCheck(videoId: videoId)
            }
            return
        }

        self.loadWatchPage(videoId: videoId)
    }

    /// Whether the open document can change track through its own player.
    ///
    /// Only a page that is being played from, that has finished loading, and whose player API has not
    /// been found unusable. Everything else is a page load, which is what Kaset always did.
    private var canSwapTrackInPage: Bool {
        guard self.webView != nil, self.page == .playback, self.isPageReady else { return false }
        return self.coordinator?.playerService.pagePlaybackCapability.canSwapTrackInPage ?? false
    }

    /// Loads a track's watch page: the long way, and the fallback for everything the page's own
    /// player cannot do.
    func loadWatchPage(videoId: String) {
        guard let webView, let urlToLoad = Self.watchURL(videoId: videoId) else { return }

        self.currentVideoId = videoId
        self.page = .playback

        // Get current volume from PlayerService via coordinator
        let currentVolume = self.coordinator?.playerService.volume ?? 1.0
        self.logger.info("Will apply volume \(currentVolume) after page load")

        // Stop current playback first, then load new video. A playback load carries no preload hold:
        // this page is meant to play.
        webView.evaluateJavaScript("document.querySelector('video')?.pause()") { [weak self] _, _ in
            guard let self, let webView = self.webView else { return }

            // Set target volume BEFORE loading so it's ready when video element appears
            let setTargetScript = "window.__kasetTargetVolume = \(currentVolume);"
            webView.evaluateJavaScript(setTargetScript, completionHandler: nil)

            webView.load(URLRequest(url: urlToLoad))
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let playerService: PlayerService

        init(playerService: PlayerService) {
            self.playerService = playerService
        }

        // MARK: Page loads

        /// A page load started: the player bar's strip has a fraction to fill now.
        func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            self.playerService.beginWebViewPageLoad()
        }

        /// A page load ended without a document. Nothing measurable is left, so the strip's fraction
        /// goes away; whether the bar keeps waiting is `PlayerBarLoadingRule`'s question.
        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
            self.playerService.finishWebViewPageLoad()
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }

            // A page that is not being played from must not report: the shell has no track, and a
            // preloaded page is a player that was told it started when its autoplay was swallowed.
            // Believing either would put a track that is not playing into the app's state.
            let observation = SingletonPlayerWebView.shared.page.observation
            guard observation != .none else { return }

            // A page Kaset is not playing from gets to report one thing only: which track it is
            // showing. Everything else it could say — its player's position, its end-of-track and
            // remote-control signals, its ads — describes playback Kaset does not want; see
            // `PlayerWebViewObservation`.
            let isAuthoritative = observation == .playback
            if !isAuthoritative, type != "STATE_UPDATE" {
                return
            }

            let observedVideoId: String? = if let videoId = body["videoId"] as? String, !videoId.isEmpty {
                videoId
            } else {
                nil
            }

            if type == "TRACK_ENDED" {
                let progress = (body["progress"] as? Double) ?? (body["progress"] as? Int).map(Double.init)
                let duration = (body["duration"] as? Double) ?? (body["duration"] as? Int).map(Double.init)
                Task { @MainActor in
                    await self.playerService.handleTrackEnded(
                        observedVideoId: observedVideoId,
                        progress: progress,
                        duration: duration
                    )
                }
                return
            }

            if type == "AD_STATE" {
                guard SettingsManager.shared.safeAdBlockingEnabled else { return }
                let isAd = body["isAd"] as? Bool ?? false
                Task { @MainActor in
                    self.playerService.updateAdPlaybackState(isAd)
                }
                return
            }

            if type == "REMOTE_NEXT" {
                Task { @MainActor in
                    await self.playerService.nextFromRemoteControl()
                }
                return
            }

            if type == "REMOTE_PREVIOUS" {
                Task { @MainActor in
                    await self.playerService.previousFromRemoteControl()
                }
                return
            }

            // Handle high frequency lyrics time updates
            if type == "LYRICS_TIME" {
                if let time = body["time"] as? Double {
                    Task { @MainActor in
                        self.playerService.currentTimeMs = Int(time * 1000)
                    }
                }
                return
            }

            // The answer to `requestVideoDimensions`: the shape of the picture this surface is
            // about to draw. Tagged with the video, so it survives reclassifying that same item.
            if type == "VIDEO_DIMENSIONS" {
                let width = (body["width"] as? Int) ?? Int((body["width"] as? Double) ?? 0)
                let height = (body["height"] as? Int) ?? Int((body["height"] as? Double) ?? 0)
                guard width > 0, height > 0 else { return }
                // The request names no video: the surface asked for the picture it is drawing, so
                // the id is the one that surface shows. Without it the observation would be
                // untagged and the next reclassification would forget a shape that is still on
                // screen — the surface would fall back to 16:9 and letterbox the picture.
                let describedVideoId = observedVideoId
                    ?? self.playerService.pendingPlayVideoId
                    ?? self.playerService.currentTrack?.videoId
                Task { @MainActor in
                    self.playerService.updateMiniPlayerVideoDimensions(
                        width: width,
                        height: height,
                        videoId: describedVideoId
                    )
                }
                return
            }

            guard type == "STATE_UPDATE" else { return }

            let isPlaying = body["isPlaying"] as? Bool ?? false
            let progress = body["progress"] as? Int ?? 0
            let duration = body["duration"] as? Int ?? 0
            let title = body["title"] as? String ?? ""
            let artist = body["artist"] as? String ?? ""
            let playerBarVideoId = body["barVideoId"] as? String
            let metadataFromPlayer = body["metadataFromPlayer"] as? Bool ?? false
            let thumbnailUrl = body["thumbnailUrl"] as? String ?? ""
            let trackChanged = body["trackChanged"] as? Bool ?? false
            let likeStatusString = body["likeStatus"] as? String ?? "INDIFFERENT"
            let hasVideo = body["hasVideo"] as? Bool ?? false
            let isAd = body["isAd"] as? Bool ?? false
            let videoWidth = (body["videoWidth"] as? Int) ?? Int((body["videoWidth"] as? Double) ?? 0)
            let videoHeight = (body["videoHeight"] as? Int) ?? Int((body["videoHeight"] as? Double) ?? 0)
            let adBlockingEnabled = SettingsManager.shared.safeAdBlockingEnabled

            // Parse like status
            let likeStatus: LikeStatus = switch likeStatusString {
            case "LIKE":
                .like
            case "DISLIKE":
                .dislike
            default:
                .indifferent
            }

            Task { @MainActor in
                guard isAuthoritative else {
                    // A preloaded page describes a performance that never happened, so none of its
                    // playback state applies — but the track it is holding does, and reconciling it
                    // here is what leaves the first press of play landing on a song that is already
                    // fully described rather than one that fills itself in seconds later.
                    self.playerService.reconcilePreloadedTrackMetadata(
                        title: title,
                        artist: artist,
                        thumbnailUrl: thumbnailUrl,
                        videoId: observedVideoId
                    )
                    return
                }

                self.playerService.updatePlaybackState(
                    isPlaying: isPlaying,
                    progress: Double(progress),
                    duration: Double(duration)
                )

                self.playerService.updateAdPlaybackState(adBlockingEnabled ? isAd : false)

                // Update video availability
                self.playerService.updateVideoAvailability(hasVideo: hasVideo)
                self.playerService.updateMiniPlayerVideoDimensions(width: videoWidth, height: videoHeight)

                // Update like status only when track changes (initial state)
                if trackChanged {
                    self.playerService.updateLikeStatus(likeStatus)
                }

                // Repeat-one must keep enforcing queue/current song even if WebView doesn't flag `trackChanged`
                // for a transient autoplay swap. In other modes, keep the existing trackChanged gate.
                // A state update that is not a track change still has to be reconciled when it carries
                // the artwork of the playing track and that track has none: nothing else would ever
                // deliver the picture, which left the now-playing art blank for the whole song (see
                // `shouldReconcileMissingArtwork`).
                let shouldReconcileMetadata = (trackChanged
                    || self.playerService.repeatMode == .one
                    || self.playerService.shouldReconcileMissingArtwork(
                        observedVideoId: observedVideoId,
                        title: title,
                        artist: artist,
                        thumbnailUrl: thumbnailUrl
                    ))
                    && (observedVideoId != nil || !title.isEmpty)

                if shouldReconcileMetadata {
                    self.playerService.updateTrackMetadata(
                        title: title,
                        artist: artist,
                        thumbnailUrl: thumbnailUrl,
                        videoId: observedVideoId,
                        playerBarVideoId: playerBarVideoId,
                        metadataFromPlayer: metadataFromPlayer
                    )
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            DiagnosticsLogger.player.info(
                "Singleton WebView finished loading: \(webView.url?.absoluteString ?? "nil")"
            )

            // The document is up; anything still to wait for is the player starting, which has no
            // fraction to report.
            self.playerService.finishWebViewPageLoad()

            // A new document has its own player: nothing learned from the previous one describes it.
            self.playerService.resetPagePlaybackBridge()

            SingletonPlayerWebView.shared.reapplyMiniPlayerPresentationIfNeeded()

            // Apply the current volume when page finishes loading
            // This is critical because YouTube may set its own default volume
            let savedVolume = self.playerService.volume
            let savedRate = self.playerService.playbackRate
            let applyVolumeScript = """
                (function() {
                    // Set target volume for enforcement
                    window.__kasetTargetVolume = \(savedVolume);
                    // Podcast playback speed survives page loads for the same reason volume does:
                    // a fresh page (track change, reload) starts at the platform default.
                    window.__kasetTargetPlaybackRate = \(savedRate);
                    const rateVideo = document.querySelector('video');
                    if (rateVideo) { rateVideo.playbackRate = \(savedRate); }
                    window.__kasetSafeAdBlockingEnabled = \(SettingsManager.shared.safeAdBlockingEnabled ? "true" : "false");
                    // Set flag to prevent enforcement from reverting our change
                    window.__kasetIsSettingVolume = true;

                    // Apply to video element if it exists
                    const video = document.querySelector('video');
                    if (video) {
                        video.volume = \(savedVolume);
                    }

                    // Sync YouTube's internal player APIs to prevent overrides
                    const ytVolume = Math.round(\(savedVolume) * 100);
                    const player = document.querySelector('ytmusic-player');
                    if (player && player.playerApi) {
                        player.playerApi.setVolume(ytVolume);
                    }
                    const moviePlayer = document.getElementById('movie_player');
                    if (moviePlayer && moviePlayer.setVolume) {
                        moviePlayer.setVolume(ytVolume);
                    }

                    // Clear flag after a moment
                    setTimeout(() => { window.__kasetIsSettingVolume = false; }, 100);

                    return video ? 'applied' : 'no-video-yet';
                })();
            """
            webView.evaluateJavaScript(applyVolumeScript) { result, error in
                if let error {
                    DiagnosticsLogger.player.error(
                        "Failed to apply saved volume \(savedVolume): \(error.localizedDescription)"
                    )
                } else if let resultString = result as? String {
                    DiagnosticsLogger.player.debug("Volume apply result: \(resultString)")
                }
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // WebView content process crashed - attempt recovery
            DiagnosticsLogger.player.error("Singleton WebView content process terminated, attempting recovery")

            // The crashed page's load is over whether or not it ever finished. What the reload shows
            // is unchanged — the same URL comes back — so which page this is stays as it was.
            self.playerService.finishWebViewPageLoad()

            // Get the current video ID before reloading
            let currentVideoId = SingletonPlayerWebView.shared.currentVideoId

            // Reload the WebView
            webView.reload()

            // If we had a video playing, reload it after a brief delay
            if let videoId = currentVideoId {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    // Reset currentVideoId to force reload
                    SingletonPlayerWebView.shared.currentVideoId = nil
                    SingletonPlayerWebView.shared.loadVideo(videoId: videoId)
                }
            }
        }
    }

    /// Keeps a page Kaset loaded only to have ready from making a sound.
    ///
    /// Kaset permits autoplay (`mediaTypesRequiringUserActionForPlayback` is empty — that is what
    /// makes playback work at all), so a watch page left to itself starts playing the moment it is up.
    /// A warm page sitting in the background must not: it would be audio the user did not ask for, on a
    /// track the app is deliberately not tracking yet. So a page carrying the preload flag swallows its
    /// own `play()` calls until the hold is lifted — by Kaset driving a control, or by the user
    /// clicking or typing in the page (the mini player's own play button is the user asking the page).
    ///
    /// Lifting the hold also realigns the page: YouTube's player was told playback started and would
    /// otherwise take the next play/pause click as a *pause*.
    private static var preloadGateScript: String {
        """
        (function() {
            'use strict';
            if (window.__kasetPreloadGateInstalled) { return; }
            window.__kasetPreloadGateInstalled = true;

            const preloadFlag = /[?&]\(Self.preloadQueryFlagName)=\(Self.preloadQueryFlagValue)/;
            window.__kasetPreloadHold = preloadFlag.test(window.location.search);

            const originalPlay = HTMLMediaElement.prototype.play;
            HTMLMediaElement.prototype.play = function() {
                if (!window.__kasetPreloadHold) {
                    return originalPlay.apply(this, arguments);
                }

                // Swallowed rather than started-and-paused: the track must not sound at all. The promise
                // is resolved so the page's own player continues as if the call had succeeded.
                try { this.pause(); } catch (error) {}
                return Promise.resolve();
            };

            function holdPlaying(event) {
                if (!window.__kasetPreloadHold) { return; }
                try { event.target.pause(); } catch (error) {}
            }

            function standDown() {
                const wasHolding = window.__kasetPreloadHold;
                window.__kasetPreloadHold = false;
                document.removeEventListener('pointerdown', standDown, true);
                document.removeEventListener('keydown', standDown, true);
                document.removeEventListener('play', holdPlaying, true);

                if (!wasHolding) { return; }

                // The page's player believes it is playing. Tell it otherwise, so the next play/pause
                // click in the page is a play.
                const player = document.querySelector('ytmusic-player');
                if (player && player.playerApi && typeof player.playerApi.pauseVideo === 'function') {
                    try { player.playerApi.pauseVideo(); } catch (error) {}
                }
                const video = document.querySelector('video');
                if (video) { try { video.pause(); } catch (error) {} }
            }

            window.__kasetPreloadStandDown = standDown;
            document.addEventListener('pointerdown', standDown, true);
            document.addEventListener('keydown', standDown, true);
            document.addEventListener('play', holdPlaying, true);
        })();
        """
    }

    /// Removes known ad payload keys from YTM responses in a defensive, no-throw way.
    private static var adPruningScript: String {
        """
        (function() {
            'use strict';
            if (window.__kasetAdPruningInstalled) return;
            window.__kasetAdPruningInstalled = true;
            if (typeof window.__kasetSafeAdBlockingEnabled !== 'boolean') {
                window.__kasetSafeAdBlockingEnabled = true;
            }

            const AD_KEYS = new Set([
                'playerAds',
                'adPlacements',
                'adSlots',
                'adBreakHeartbeatParams'
            ]);

            function prune(node) {
                if (window.__kasetSafeAdBlockingEnabled === false) return;
                if (!node || typeof node !== 'object') return;
                if (Array.isArray(node)) {
                    for (const item of node) prune(item);
                    return;
                }
                for (const key of Object.keys(node)) {
                    if (AD_KEYS.has(key)) {
                        delete node[key];
                        continue;
                    }
                    prune(node[key]);
                }
            }

            function patchJsonResponseBody(body) {
                if (!body || typeof body !== 'object') return body;
                try {
                    const clone = typeof structuredClone === 'function'
                        ? structuredClone(body)
                        : JSON.parse(JSON.stringify(body));
                    prune(clone);
                    return clone;
                } catch (_) {
                    return body;
                }
            }

            const originalJsonParse = JSON.parse;
            JSON.parse = function(text, reviver) {
                const parsed = originalJsonParse.call(this, text, reviver);
                prune(parsed);
                return parsed;
            };

            const originalFetch = window.fetch;
            if (typeof originalFetch === 'function') {
                window.fetch = async function(...args) {
                    const response = await originalFetch.apply(this, args);
                    if (!response || typeof response.clone !== 'function') return response;

                    try {
                        const contentType = response.headers.get('content-type') || '';
                        if (!contentType.includes('application/json')) return response;

                        const json = await response.clone().json();
                        const pruned = patchJsonResponseBody(json);
                        return new Response(JSON.stringify(pruned), {
                            status: response.status,
                            statusText: response.statusText,
                            headers: response.headers
                        });
                    } catch (_) {
                        return response;
                    }
                };
            }
        })();
        """
    }
}

// MARK: - SingletonPlayerWebView Media Controls

extension SingletonPlayerWebView {
    /// Updates the current page and the bootstrap state used by future page loads.
    func setMediaControlStyle(useNextPrev: Bool) {
        self.mediaControlUsesNextPrev = useNextPrev

        guard let webView = self.webView else { return }
        let script = Self.mediaControlStyleSyncScript(useNextPrev: useNextPrev)
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func mediaControlBootstrapScript() -> String {
        Self.mediaControlStyleBootstrapScript(useNextPrev: self.mediaControlUsesNextPrev)
    }

    static func mediaControlStyleBootstrapScript(useNextPrev: Bool) -> String {
        let jsBoolean = useNextPrev ? "true" : "false"
        return """
            (function() {
                try {
                    localStorage.setItem('kasetUseNextPrev', '\(jsBoolean)');
                } catch (e) {}
                window.__kasetUseNextPrev = \(jsBoolean);
            })();
        """
    }

    static func mediaControlStyleSyncScript(useNextPrev: Bool) -> String {
        let jsBoolean = useNextPrev ? "true" : "false"
        let restoreSeekHandlers = if useNextPrev {
            ""
        } else {
            """
                try {
                    var ms = navigator.mediaSession;
                    ms.setActionHandler('nexttrack', null);
                    ms.setActionHandler('previoustrack', null);
                    ms.setActionHandler('seekforward', function(d) {
                        var v = document.querySelector('video');
                        if (v) v.currentTime = Math.min(v.duration,
                            v.currentTime + ((d && d.seekOffset) || 15));
                    });
                    ms.setActionHandler('seekbackward', function(d) {
                        var v = document.querySelector('video');
                        if (v) v.currentTime = Math.max(0,
                            v.currentTime - ((d && d.seekOffset) || 15));
                    });
                } catch (e) {}
            """
        }

        return """
            (function() {
                try {
                    localStorage.setItem('kasetUseNextPrev', '\(jsBoolean)');
                } catch (e) {}
                window.__kasetUseNextPrev = \(jsBoolean);
                if (typeof window.__kasetRefreshMediaControlStyle === 'function') {
                    window.__kasetRefreshMediaControlStyle();
                }
                \(restoreSeekHandlers)
            })();
        """
    }

    static var mediaControlOverrideScript: String {
        """
        (function() {
            if (typeof window.__kasetUseNextPrev !== 'boolean') {
                try {
                    window.__kasetUseNextPrev =
                        localStorage.getItem('kasetUseNextPrev') === 'true';
                } catch (e) {
                    window.__kasetUseNextPrev = false;
                }
            }

            var overrideFrameId = null;

            function applyOverride() {
                if (!window.__kasetUseNextPrev) {
                    return;
                }
                try {
                    var ms = navigator.mediaSession;
                    ms.setActionHandler('seekforward', null);
                    ms.setActionHandler('seekbackward', null);
                    ms.setActionHandler('nexttrack', function() {
                        window.webkit.messageHandlers.singletonPlayer
                            .postMessage({ type: 'REMOTE_NEXT' });
                    });
                    ms.setActionHandler('previoustrack', function() {
                        window.webkit.messageHandlers.singletonPlayer
                            .postMessage({ type: 'REMOTE_PREVIOUS' });
                    });
                } catch (e) {}
            }

            function scheduleOverrideLoop() {
                if (overrideFrameId !== null || !window.__kasetUseNextPrev) {
                    return;
                }

                overrideFrameId = requestAnimationFrame(function() {
                    overrideFrameId = null;
                    if (!window.__kasetUseNextPrev) {
                        return;
                    }
                    applyOverride();
                    scheduleOverrideLoop();
                });
            }

            window.__kasetRefreshMediaControlStyle = function() {
                applyOverride();
                scheduleOverrideLoop();
            };

            window.__kasetRefreshMediaControlStyle();

            // Re-apply on video events where YouTube re-registers handlers.
            function attachVideoOverride() {
                var v = document.querySelector('video');
                if (!v || v.__kasetOverrideAttached) return;
                v.__kasetOverrideAttached = true;
                ['playing','loadedmetadata','loadeddata','canplay','seeked']
                    .forEach(function(e) { v.addEventListener(e, applyOverride); });
            }

            attachVideoOverride();
            new MutationObserver(attachVideoOverride)
                .observe(document.documentElement, {childList:true, subtree:true});
        })();
        """
    }
}
