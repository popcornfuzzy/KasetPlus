import WebKit

// MARK: - SingletonPlayerWebView Page Playback

/// Swaps the track inside the open document, and asks the page which track it is playing.
///
/// A track change used to be a page navigation. That pays for the whole document every time: the JS
/// bundle, the player, the DRM session, and the first render of the player bar — which is why the bar
/// has a loading strip at all. The page's own player can load a track into the open document, and that
/// is a fraction of the cost.
///
/// Deliberately the *only* thing asked of the page. Kaset does not install its queue there, adapt
/// YouTube's queue, or advance the page's queue: YouTube Music's player bar and its store follow its own
/// queue, and rewriting that behind its back is what leaves the bar describing a track that is no
/// longer playing. Kaset's queue stays the only queue that means anything; the page is asked to play one
/// track at a time, and it is checked that it did.
///
/// Every call answers with a status (see ``WebPagePlaybackStatus``). A page that cannot swap is
/// reported, never assumed, and the caller navigates instead.
extension SingletonPlayerWebView {
    /// Installs the bridge into the page (idempotent; safe on every document).
    ///
    /// Feature-detected and no-throw throughout: a page whose player API changed shape answers
    /// `no-player`, and playback falls back to the page loads Kaset always did.
    static var pagePlaybackBridgeScript: String {
        """
        (function() {
            'use strict';
            if (window.__kasetPlayback) { return; }

            function playerApi() {
                const player = document.querySelector('ytmusic-player');
                if (player && player.playerApi) { return player.playerApi; }
                const moviePlayer = document.getElementById('movie_player');
                if (moviePlayer && typeof moviePlayer.loadVideoById === 'function') { return moviePlayer; }
                return null;
            }

            function currentVideoId(api) {
                try {
                    const data = api.getVideoData ? api.getVideoData() : null;
                    if (data && typeof data === 'object') {
                        return data.video_id || data.videoId || '';
                    }
                } catch (error) {}
                return '';
            }

            function playlistOf(api) {
                try {
                    const list = api.getPlaylist ? api.getPlaylist() : null;
                    return Array.isArray(list) ? list : null;
                } catch (error) { return null; }
            }

            function ensurePlaying(api) {
                try {
                    const video = document.querySelector('video');
                    if (!video || !video.paused) { return; }
                    if (typeof api.playVideo === 'function') { api.playVideo(); }
                    else { video.play(); }
                } catch (error) {}
            }

            window.__kasetPlayback = {
                // Starts `videoId` in the open document. Returns a WebPagePlaybackStatus.
                play: function(videoId) {
                    if (!videoId) { return 'error'; }
                    const api = playerApi();
                    if (!api) { return 'no-player'; }

                    if (currentVideoId(api) === videoId) {
                        ensurePlaying(api);
                        return 'already-playing';
                    }

                    // The page's own queue already holds the track: jumping to it is the cheapest and
                    // most faithful thing the page can do, since it is the page's own row.
                    const ids = playlistOf(api);
                    const index = ids ? ids.indexOf(videoId) : -1;
                    if (index >= 0 && typeof api.playVideoAt === 'function') {
                        try {
                            api.playVideoAt(index);
                            ensurePlaying(api);
                            return 'played-at';
                        } catch (error) {}
                    }

                    // Positional form on purpose: it is the signature the player has always had, while
                    // the object form is not honoured everywhere. A load the player does not understand
                    // can resume at the old position and end immediately, which advances the queue
                    // again the moment the new track starts.
                    if (typeof api.loadVideoById === 'function') {
                        try {
                            api.loadVideoById(videoId, 0);
                            return 'loaded-video';
                        } catch (error) {}
                    }
                    return 'error';
                },

                // The track the page's player holds, or '' when it will not say.
                current: function() {
                    const api = playerApi();
                    if (!api) { return ''; }
                    return currentVideoId(api);
                }
            };
        })();
        """
    }

    /// Builds the call that starts `videoId` inside the open document.
    ///
    /// Pure construction, so the exact snippet the app injects can be driven against a mock page.
    static func pagePlayScript(videoId: String) -> String {
        """
        (function() {
            const playback = window.__kasetPlayback;
            if (!playback) { return 'not-installed'; }
            try {
                return playback.play(\(Self.javaScriptStringLiteral(videoId)));
            } catch (error) {
                return 'error';
            }
        })();
        """
    }

    /// Builds the call that asks the page which track it is playing.
    static func pageCurrentScript() -> String {
        """
        (function() {
            const playback = window.__kasetPlayback;
            if (!playback) { return ''; }
            try { return playback.current(); } catch (error) { return ''; }
        })();
        """
    }

    /// A JavaScript string literal for `value`, escaped by the JSON encoder so an id can never break
    /// out of the snippet.
    static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return literal
    }

    /// Asks the page's player to start `videoId`, reporting the status it answered with.
    ///
    /// The completion is always called on the main actor and always exactly once — with `error` when the
    /// page script itself failed, which lets the caller take the page-load path without knowing
    /// anything about JavaScript.
    func playInPage(videoId: String, completion: @escaping (String) -> Void) {
        guard let webView else {
            completion(WebPagePlaybackStatus.noPlayer)
            return
        }

        webView.evaluateJavaScript(Self.pagePlayScript(videoId: videoId)) { result, error in
            if let error {
                self.logger.debug("In-page play failed: \(error.localizedDescription)")
            }
            let status = (result as? String) ?? WebPagePlaybackStatus.failed
            Task { @MainActor in completion(status) }
        }
    }

    /// Asks the page which track its player holds, for the settle check.
    func requestPageCurrentVideoId(completion: @escaping (String?) -> Void) {
        guard let webView else {
            completion(nil)
            return
        }

        webView.evaluateJavaScript(Self.pageCurrentScript()) { result, _ in
            let videoId = result as? String
            Task { @MainActor in
                completion(videoId?.isEmpty == false ? videoId : nil)
            }
        }
    }
}
