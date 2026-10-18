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
        <div id="player-wrap"><video id="v"></video></div>
        <button id="songtab" aria-selected="false">Song</button>
        <button id="videotab" aria-selected="true">Video</button>
        <script>
        const v = document.getElementById('v');
        Object.defineProperty(v, 'readyState', { get: () => 4 });
        Object.defineProperty(v, 'videoWidth', { get: () => 1280 });
        Object.defineProperty(v, 'videoHeight', { get: () => 720 });
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

    private final class Harness: NSObject, WKNavigationDelegate {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        private var loadContinuation: CheckedContinuation<Void, Never>?

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            self.loadContinuation?.resume()
            self.loadContinuation = nil
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            self.loadContinuation?.resume()
            self.loadContinuation = nil
        }

        func loadMockPage() async {
            self.webView.navigationDelegate = self
            await withCheckedContinuation { continuation in
                self.loadContinuation = continuation
                self.webView.loadHTMLString(VideoPresentationScriptTests.mockPage, baseURL: nil)
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

        func applyPresentation(isExpanded: Bool, prefersVideo: Bool) async {
            let script = SingletonPlayerWebView.miniPlayerPresentationScript(
                isExpanded: isExpanded,
                prefersVideo: prefersVideo
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

    @Test("A swapped video element is healed back into the container")
    func swappedVideoElementHeals() async {
        let harness = await self.makeHarness()
        await harness.applyPresentation(isExpanded: true, prefersVideo: true)
        #expect(await harness.waitFor(Self.liveVideoExpr, timeoutMs: 5_000))

        // YouTube re-renders and reclaims the node (Song/Video tab switch
        // completing late, player re-render).
        await harness.run(
            "document.getElementById('player-wrap').appendChild(document.querySelector('video'))"
        )
        #expect(await harness.evalBool(Self.liveVideoExpr) == false)

        #expect(await harness.waitFor(Self.liveVideoExpr, timeoutMs: 4_000))
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
}
