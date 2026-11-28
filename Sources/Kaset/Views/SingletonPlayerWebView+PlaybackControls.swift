import WebKit

// MARK: - SingletonPlayerWebView Playback Controls Extension

extension SingletonPlayerWebView {
    /// The WebView, when the page in it is one Kaset's transport may drive.
    ///
    /// A page with no track of Kaset's — the shell, or nothing at all — is refused here rather than in
    /// every caller: a command aimed at it would start the page's own player, which the app cannot
    /// name and does not believe (see ``PlayerWebViewPage/acceptsPlaybackCommands``).
    private func transportWebView() -> WKWebView? {
        guard let webView else { return nil }
        guard self.page.acceptsPlaybackCommands else {
            self.logger.debug("Ignoring a playback command: the \(String(describing: self.page)) page carries no track")
            return nil
        }
        return webView
    }

    /// Toggle play/pause.
    func playPause() {
        guard let webView = self.transportWebView() else { return }

        // The user asked for sound: a preloaded page stops being held before it is toggled.
        self.releasePreloadHold()

        let script = """
            (function() {
                const playBtn = document.querySelector('.play-pause-button.ytmusic-player-bar');
                if (playBtn) { playBtn.click(); return 'clicked'; }
                const video = document.querySelector('video');
                if (video) {
                    if (video.paused) { video.play(); return 'played'; }
                    else { video.pause(); return 'paused'; }
                }
                return 'no-element';
            })();
        """
        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                self?.logger.error("playPause error: \(error.localizedDescription)")
            }
        }
    }

    /// Play (resume).
    func play() {
        guard let webView = self.transportWebView() else { return }

        self.releasePreloadHold()

        let script = """
            (function() {
                const video = document.querySelector('video');
                if (video && video.paused) { video.play(); return 'played'; }
                return 'already-playing';
            })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Pause.
    func pause() {
        guard let webView = self.transportWebView() else { return }

        let script = """
            (function() {
                const video = document.querySelector('video');
                if (video && !video.paused) { video.pause(); return 'paused'; }
                return 'already-paused';
            })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Skip to next track.
    func next() {
        guard let webView = self.transportWebView() else { return }

        self.releasePreloadHold()

        let script = """
            (function() {
                const nextBtn = document.querySelector('.next-button.ytmusic-player-bar');
                if (nextBtn) { nextBtn.click(); return 'clicked'; }
                return 'no-button';
            })();
        """
        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                self?.logger.error("next error: \(error.localizedDescription)")
            }
        }
    }

    /// Go to previous track.
    func previous() {
        guard let webView = self.transportWebView() else { return }

        self.releasePreloadHold()

        let script = """
            (function() {
                const prevBtn = document.querySelector('.previous-button.ytmusic-player-bar');
                if (prevBtn) { prevBtn.click(); return 'clicked'; }
                return 'no-button';
            })();
        """
        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                self?.logger.error("previous error: \(error.localizedDescription)")
            }
        }
    }

    /// Seek to a specific time in seconds.
    func seek(to time: Double) {
        guard let webView else { return }

        let script = """
            (function() {
                const video = document.querySelector('video');
                if (video) { video.currentTime = \(time); return 'seeked'; }
                return 'no-video';
            })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Sets the playback rate (0.25x – 4x) and records it as the target the page keeps enforcing.
    func setPlaybackRate(_ rate: Double) {
        guard let webView = self.webView else { return }
        let clampedRate = max(0.25, min(4, rate))

        let script = """
            (function() {
                window.__kasetTargetPlaybackRate = \(clampedRate);
                const video = document.querySelector('video');
                if (!video) { return 'no-video'; }
                video.playbackRate = \(clampedRate);
                return 'rate=' + video.playbackRate;
            })();
        """
        webView.evaluateJavaScript(script) { [weak self] result, error in
            if let error {
                self?.logger.error("setPlaybackRate error: \(error.localizedDescription)")
            } else if let resultString = result as? String {
                self?.logger.debug("Playback rate result: \(resultString)")
            }
        }
    }

    /// Puts the page's playback at `time` once its media can seek, and leaves it playing or paused.
    ///
    /// A variant switch loads a different upload of the same track, which begins at zero like any
    /// track load, so the position has to be put back. The media element exists before it can seek
    /// (and before it has a duration), hence the bounded retry rather than one attempt.
    func seekWhenReady(to time: Double, resumesPlayback: Bool) {
        guard let webView else { return }

        let script = """
            (function() {
                const target = \(time);
                const shouldPlay = \(resumesPlayback ? "true" : "false");
                const maxAttempts = 48;
                const holdTicks = 12;
                let attempts = 0;
                let applied = false;
                let ticksSinceApply = 0;

                function applyPosition(video) {
                    if (target > 0) {
                        video.currentTime = Math.min(target, Math.max(0, video.duration - 0.5));
                    }
                    if (shouldPlay) {
                        const play = video.play();
                        if (play && typeof play.catch === 'function') play.catch(function() {});
                    } else {
                        video.pause();
                    }
                }

                const timer = setInterval(function() {
                    attempts += 1;
                    const video = document.querySelector('video');
                    const playable = video && video.readyState >= 1
                        && isFinite(video.duration) && video.duration > 0;

                    if (playable && !applied) {
                        applied = true;
                        applyPosition(video);
                        return;
                    }

                    if (playable && applied) {
                        // The page can restart the media after the switch (its own tab
                        // selection does). The position belongs to the track, not to the upload.
                        ticksSinceApply += 1;
                        if (target > 0 && video.currentTime < 2 && Math.abs(video.currentTime - target) > 3) {
                            applyPosition(video);
                        }
                        if (ticksSinceApply > holdTicks) { clearInterval(timer); }
                        return;
                    }

                    if (attempts >= maxAttempts) { clearInterval(timer); }
                }, 250);
            })();
            """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Pauses the page as soon as it has media to pause.
    ///
    /// A pause asked for while a track is loading cannot be applied yet: the document's player may
    /// not exist, and YouTube Music starts the track itself as soon as it can. This keeps the request
    /// and takes the first media it sees, for a bounded time, so the track does not start sounding
    /// after the reader paused it.
    func pauseWhenReady() {
        guard let webView else { return }
        webView.evaluateJavaScript(
            """
            (function() {
                window.__kasetPauseWhenReady = true;

                function pauseMedia() {
                    try {
                        const videos = document.querySelectorAll('video');
                        for (let index = 0; index < videos.length; index++) {
                            const video = videos[index];
                            if (!video.paused) { video.pause(); }
                        }
                    } catch (error) {}
                }

                pauseMedia();
                if (window.__kasetPauseWhenReadyTimer) { return; }

                let attempts = 0;
                window.__kasetPauseWhenReadyTimer = setInterval(function() {
                    attempts += 1;
                    if (!window.__kasetPauseWhenReady || attempts >= 80) {
                        clearInterval(window.__kasetPauseWhenReadyTimer);
                        window.__kasetPauseWhenReadyTimer = null;
                        return;
                    }
                    pauseMedia();
                }, 250);
            })();
            """,
            completionHandler: nil
        )
    }

    /// Cancels a pending ``pauseWhenReady()`` (a play request replaced it).
    func cancelPauseWhenReady() {
        guard let webView else { return }
        webView.evaluateJavaScript(
            """
            window.__kasetPauseWhenReady = false;
            if (window.__kasetPauseWhenReadyTimer) {
                clearInterval(window.__kasetPauseWhenReadyTimer);
                window.__kasetPauseWhenReadyTimer = null;
            }
            """,
            completionHandler: nil
        )
    }

    /// Seeks to the start and resumes playback without a full page load (repeat-one, same-URL recovery).
    func restartInPlaceFromBeginning() {
        self.seek(to: 0)
        self.play()
    }

    /// Set volume (0.0 - 1.0).
    func setVolume(_ volume: Double) {
        guard let webView else { return }
        let clampedVolume = max(0, min(1, volume))

        // Update target volume and set video volume directly
        // Also try to set YouTube's internal player volume via their API
        let script = """
            (function() {
                window.__kasetTargetVolume = \(clampedVolume);
                const video = document.querySelector('video');
                let result = [];

                if (video) {
                    // Set flag to prevent volumechange listener from reverting
                    window.__kasetIsSettingVolume = true;
                    video.volume = \(clampedVolume);
                    result.push('video.volume=' + video.volume);
                    setTimeout(() => { window.__kasetIsSettingVolume = false; }, 50);
                } else {
                    result.push('no-video');
                }

                // Also try YouTube Music's internal player API
                const player = document.querySelector('ytmusic-player');
                if (player && player.playerApi) {
                    const ytVolume = Math.round(\(clampedVolume) * 100);
                    player.playerApi.setVolume(ytVolume);
                    result.push('ytapi.setVolume=' + ytVolume);
                }

                // Try movie_player API as fallback
                const moviePlayer = document.getElementById('movie_player');
                if (moviePlayer && moviePlayer.setVolume) {
                    const ytVolume = Math.round(\(clampedVolume) * 100);
                    moviePlayer.setVolume(ytVolume);
                    result.push('movie_player.setVolume=' + ytVolume);
                }

                return result.join(', ');
            })();
        """
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                self.logger.error("setVolume error: \(error.localizedDescription)")
            }
        }
    }
}
