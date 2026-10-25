import Foundation
import Testing
import WebKit
@testable import Kaset

/// Drives the exact DOM presentation script the app injects against a mock
/// YouTube-like page in a real WKWebView, so host handoffs (podcast fullscreen
/// exit, sidebar toggles) are reproducible without the app GUI.
///
/// The mock page has a Song/Video tab pair and a `<video>` element whose frame
/// data is faked (no media loads in tests), so the script's extraction gates
/// behave as they do with a playing video.
@Suite(.serialized, .tags(.service, .slow))
@MainActor
struct VideoPresentationScriptTests {
    // MARK: - Harness

    private static let mockPage = """
        <html><head></head><body>
        <div id="player-wrap"></div>
        <button id="songtab" aria-selected="false">Song</button>
        <button id="videotab" aria-selected="true">Video</button>
        <script>
        // The media element is faked: no media loads in tests, so the extraction gates
        // (frame decoded, still playing) behave as they do with a playing video.
        window.__frameReady = true;
        window.makeVideo = function(id) {
            const video = document.createElement('video');
            video.id = id;
            video.__playing = true;
            Object.defineProperty(video, 'readyState', { get: () => (window.__frameReady ? 4 : 0) });
            Object.defineProperty(video, 'videoWidth', { get: () => (window.__frameReady ? 1280 : 0) });
            Object.defineProperty(video, 'videoHeight', { get: () => (window.__frameReady ? 720 : 0) });
            Object.defineProperty(video, 'paused', { get: () => !video.__playing });
            return video;
        };
        document.getElementById('player-wrap').appendChild(window.makeVideo('v'));
        // Clicking the video tab selects it, like YouTube's own tab switch.
        document.getElementById('videotab').addEventListener('click', () => {
            document.getElementById('videotab').setAttribute('aria-selected', 'true');
            document.getElementById('songtab').setAttribute('aria-selected', 'false');
        });
        </script>
        </body></html>
        """

    /// The script's own liveness predicate, mirrored for assertions.
    private static let liveVideoExpr = """
        !!(function() {
            const c = document.getElementById('kaset-video-container');
            const v = document.querySelector('video');
            return c && v && v.parentElement === c;
        })()
        """

    private final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        /// Messages the page posted to the app, in order.
        private(set) var received: [[String: Any]] = []
        private var loadContinuation: CheckedContinuation<Void, Never>?

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            self.received.append(body)
        }

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            self.loadContinuation?.resume()
            self.loadContinuation = nil
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            self.loadContinuation?.resume()
            self.loadContinuation = nil
        }

        func loadMockPage(baseURL: URL? = nil) async {
            self.webView.navigationDelegate = self
            await withCheckedContinuation { continuation in
                self.loadContinuation = continuation
                self.webView.loadHTMLString(VideoPresentationScriptTests.mockPage, baseURL: baseURL)
            }
            self.webView.navigationDelegate = nil
        }

        /// Runs a script, discarding its value.
        func run(_ script: String) async {
            await withCheckedContinuation { continuation in
                self.webView.evaluateJavaScript(script) { _, _ in
                    continuation.resume()
                }
            }
        }

        /// Evaluates a JS boolean expression.
        func evalBool(_ script: String) async -> Bool {
            await withCheckedContinuation { continuation in
                self.webView.evaluateJavaScript(script) { value, _ in
                    continuation.resume(returning: value as? Bool == true)
                }
            }
        }

        /// Evaluates a JS expression to its string value.
        func evalString(_ script: String) async -> String? {
            await withCheckedContinuation { continuation in
                self.webView.evaluateJavaScript(script) { value, _ in
                    continuation.resume(returning: value as? String)
                }
            }
        }

        func applyPresentation(isExpanded: Bool, prefersVideo: Bool, fillsSurface: Bool = false) async {
            let script = SingletonPlayerWebView.miniPlayerPresentationScript(
                isExpanded: isExpanded,
                prefersVideo: prefersVideo,
                fillsSurface: fillsSurface
            )
            await self.run(script)
        }

        /// Polls a JS boolean until true or the timeout elapses.
        func waitFor(_ condition: String, timeoutMs: Int) async -> Bool {
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while Date() < deadline {
                if await self.evalBool(condition) { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return await self.evalBool(condition)
        }
    }

    private func makeHarness() async -> Harness {
        let harness = Harness()
        harness.webView.configuration.userContentController.add(harness, name: "singletonPlayer")
        await harness.loadMockPage()
        return harness
    }

    // MARK: - Tests

    @Test("Expanded presentation puts the live video in the container")
    func expandedExtractsLiveVideo() async {
        let harness = await self.makeHarness()
        await harness.applyPresentation(isExpanded: true, prefersVideo: true)
        #expect(await harness.waitFor(Self.liveVideoExpr, timeoutMs: 5_000))
    }

    @Test("Podcast-exit handoff: parking keeps the extraction, re-expand is instant")
    func podcastExitHandoffKeepsVideoLive() async {
        let harness = await self.makeHarness()
        await harness.applyPresentation(isExpanded: true, prefersVideo: true)
        #expect(await harness.waitFor(Self.liveVideoExpr, timeoutMs: 5_000))

        // The hidden 1x1 layer parks while the sidebar mounts.
        await harness.applyPresentation(isExpanded: false, prefersVideo: false)
        try? await Task.sleep(for: .milliseconds(1_500))

        // The extraction must survive parking: tearing it down here is what
        // forced an async rebuild that could miss and leave a black box.
        #expect(await harness.evalBool(Self.liveVideoExpr))

        // The sidebar takes over: same page, same video — instantly live.
        await harness.applyPresentation(isExpanded: true, prefersVideo: true)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await harness.evalBool(Self.liveVideoExpr))
    }

    /// YouTube can replace the element that plays the sound at any moment (Song/Video switch
    /// completing late, player re-render, a new stream). The picture must follow it in the same
    /// task: healing is a microtask, which runs before the browser paints, so there is no frame
    /// in which the surface is empty — the old one-second poll could show a black box for a
    /// whole second.
    @Test("A replaced video element is shown in the same task, before any repaint")
    func replacedVideoIsShownImmediately() async {
        let harness = await self.makeHarness()
        await harness.applyPresentation(isExpanded: true, prefersVideo: true)
        #expect(await harness.waitFor(Self.liveVideoExpr, timeoutMs: 5_000))

        await harness.run("""
            (function() {
                document.getElementById('player-wrap').appendChild(window.makeVideo('v2'));
                document.getElementById('v').remove();
            })();
            """)

        #expect(await harness.evalBool(
            "document.getElementById('kaset-video-container').firstElementChild.id === 'v2'"
        ))
    }

    /// The failure that used to persist: the container still holds a video, but it is not the
    /// one playing any more. The old liveness check ("is some video in the container?") saw a
    /// healthy surface and healed nothing, so the box stayed black for as long as the track.
    @Test("A dead video in the container is replaced by the one that is playing")
    func deadVideoIsReplacedByThePlayingOne() async {
        let harness = await self.makeHarness()
        await harness.applyPresentation(isExpanded: true, prefersVideo: true)
        #expect(await harness.waitFor(
            "document.getElementById('kaset-video-container').firstElementChild.id === 'v'",
            timeoutMs: 5_000
        ))

        await harness.run("""
            (function() {
                document.getElementById('v').__playing = false;
                document.getElementById('player-wrap').appendChild(window.makeVideo('v2'));
            })();
            """)

        #expect(await harness.evalBool("""
            (function() {
                const container = document.getElementById('kaset-video-container');
                return container.children.length === 1
                    && container.firstElementChild.id === 'v2';
            })()
            """))
    }

    /// The surface must never show the page instead of the picture: until a video has decoded a
    /// frame there is nothing to draw, so the page stays covered (black), not uncovered.
    @Test("The page stays covered until the video has a frame")
    func pageStaysCoveredUntilTheVideoHasAFrame() async {
        let harness = await self.makeHarness()
        await harness.run("window.__frameReady = false")
        await harness.applyPresentation(isExpanded: true, prefersVideo: true)

        try? await Task.sleep(for: .milliseconds(400))
        #expect(await harness.evalBool("document.getElementById('kaset-video-blackout') != null"))
        #expect(await harness.evalBool(Self.liveVideoExpr) == false)

        // The stream decodes its first frame: the picture arrives and the page is uncovered.
        await harness.run("""
            window.__frameReady = true;
            document.getElementById('v').dispatchEvent(new Event('loadeddata'));
            """)

        #expect(await harness.waitFor(Self.liveVideoExpr, timeoutMs: 2_000))
        #expect(await harness.evalBool("document.getElementById('kaset-video-blackout') == null"))
    }

    /// The shape of the picture is reported by the page the moment the surface draws it — also
    /// while the video is only playing in the invisible layer. The sidebar's surface is sized from
    /// that ratio, so learning it before the switch is what keeps the box the picture's own shape
    /// from the first frame; asking only after the switch leaves the 16:9 fallback up for a moment,
    /// and anything that is not 16:9 is letterboxed inside it (black bars around the video).
    @Test("The page reports the picture's shape as soon as it draws it")
    func thePageReportsThePicturesShape() async {
        let harness = await self.makeHarness()
        await harness.applyPresentation(isExpanded: true, prefersVideo: true)
        #expect(await harness.waitFor(Self.liveVideoExpr, timeoutMs: 5_000))

        let shapes = harness.received.filter { $0["type"] as? String == "VIDEO_DIMENSIONS" }
        #expect(shapes.contains { message in
            (message["width"] as? NSNumber)?.intValue == 1280
                && (message["height"] as? NSNumber)?.intValue == 720
        })
    }

    /// A surface drawn at the video's own ratio has nothing to letterbox: `contain` there paints
    /// the difference between that ratio and the surface's coordinates as a black hairline along
    /// the edges, so the picture fills it (`cover`) instead. A surface whose ratio was imposed
    /// keeps the whole picture.
    @Test("A surface sized to the video fills it; an imposed surface letterboxes")
    func objectFitFollowsTheSurface() async {
        let harness = await self.makeHarness()
        let fit = "getComputedStyle(document.querySelector('video')).objectFit"

        // The rule only reaches the video once the extraction has put it in the container.
        await harness.applyPresentation(isExpanded: true, prefersVideo: true, fillsSurface: true)
        #expect(await harness.waitFor(Self.liveVideoExpr, timeoutMs: 5_000))
        #expect(await harness.evalString(fit) == "cover")

        // Only the surface's meaning changed: the presentation must be re-applied for it.
        await harness.applyPresentation(isExpanded: true, prefersVideo: true, fillsSurface: false)
        #expect(await harness.waitFor("\(fit) === 'contain'", timeoutMs: 3_000))
    }

    @Test("Tab selection is a one-shot intent: clicked once, never by the watchdog")
    func videoTabSelectionIsOneShot() async {
        let harness = await self.makeHarness()
        await harness.run(
            "document.getElementById('videotab').setAttribute('aria-selected', 'false')"
        )
        await harness.applyPresentation(isExpanded: true, prefersVideo: true)

        #expect(await harness.waitFor(
            "document.getElementById('videotab').getAttribute('aria-selected') === 'true'",
            timeoutMs: 5_000
        ))

        // The explicit attempt is done and only the healing watchdog is left. The tab loses
        // selection (a late player re-render); healing must never click, because a stray
        // click can navigate the player — and the drift handlers answer navigation with a
        // full reload out from under the showing video.
        #expect(await harness.waitFor(
            "window.__kasetMiniPlayerVideoTimer == null", timeoutMs: 5_000
        ))
        await harness.run(
            "document.getElementById('videotab').setAttribute('aria-selected', 'false')"
        )
        try? await Task.sleep(for: .milliseconds(1_500))

        #expect(await harness.evalBool(
            "document.getElementById('videotab').getAttribute('aria-selected') === 'false'"
        ))
        #expect(await harness.evalBool(Self.liveVideoExpr))
    }

    /// A navigation replaces the whole document, taking the container and blackout with it.
    /// The presentation state is remembered, so the next document covers itself at parse time
    /// rather than painting YouTube Music's own player chrome into the video surface.
    @Test("A page loaded while the surface is showing covers itself at document start")
    func loadedPageCoversItselfWhenTheSurfaceIsShowing() async {
        let harness = Harness()
        await harness.loadMockPage(baseURL: URL(string: "https://music.youtube.com"))

        await harness.run(
            "sessionStorage.setItem('\(SingletonPlayerWebView.presentationStorageKey)', '1')"
        )
        await harness.run(SingletonPlayerWebView.presentationCoverScript)
        #expect(await harness.evalString("getComputedStyle(document.body).visibility") == "hidden")

        // Parking records '0': a page loaded for audio only is not covered.
        await harness.run("document.getElementById('kaset-presentation-cover')?.remove()")
        await harness.run(
            "sessionStorage.setItem('\(SingletonPlayerWebView.presentationStorageKey)', '0')"
        )
        await harness.run(SingletonPlayerWebView.presentationCoverScript)
        #expect(await harness.evalString("getComputedStyle(document.body).visibility") == "visible")
    }
}
