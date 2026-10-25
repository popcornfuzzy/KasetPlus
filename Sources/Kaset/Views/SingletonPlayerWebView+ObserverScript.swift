// MARK: - SingletonPlayerWebView Observer Script Extension

extension SingletonPlayerWebView {
    /// Observer script for playback state.
    static var observerScript: String {
        """
        (function() {
            'use strict';
            const bridge = window.webkit.messageHandlers.singletonPlayer;
            let lastTitle = '';
            let lastArtist = '';
            let lastVideoId = '';
            let isPollingActive = false;
            let pollIntervalId = null;
            let lastUpdateTime = 0;
            let lastAdState = null;
            const UPDATE_THROTTLE_MS = 500; // Throttle updates to max 2/sec
            const POLL_INTERVAL_MS = 1000; // Poll at 1Hz during playback (reduced from 250ms)
            const TAIL_POLL_INTERVAL_MS = 1000;
            // How long the observer keeps watching after a track ends. Playback can continue into a
            // track the app did not start (the page's own advance, autoplay), and polling that
            // stopped with the ended video left the app showing the song that had finished.
            const TAIL_POLL_TICKS = 12;
            let tailPollId = null;

            // Volume enforcement: track target volume set by Swift
            // Don't set a default - only enforce when explicitly set by Swift
            // window.__kasetTargetVolume is set by volume init script at document start
            let isEnforcingVolume = false; // Prevent feedback loops

            // Playback-rate enforcement: track the podcast speed set by Swift.
            // window.__kasetTargetPlaybackRate is set by the rate control script.
            let isEnforcingRate = false; // Prevent feedback loops

            // YouTube recreates the video element (and resets the rate) on track changes
            // and ad transitions, so the target rate is re-asserted rather than set once.
            function enforcePlaybackRateNow() {
                const targetRate = window.__kasetTargetPlaybackRate;
                const v = document.querySelector('video');
                if (!v || typeof targetRate !== 'number') return;
                if (Math.abs(v.playbackRate - targetRate) <= 0.01) return;
                isEnforcingRate = true;
                v.playbackRate = targetRate;
                setTimeout(() => { isEnforcingRate = false; }, 50);
            }

            // Reusable 3-way volume enforcement (video element + YouTube APIs)
            function enforceVolumeNow() {
                const targetVol = window.__kasetTargetVolume;
                const v = document.querySelector('video');
                if (!v || typeof targetVol !== 'number' || Math.abs(v.volume - targetVol) <= 0.01) return;
                isEnforcingVolume = true;
                v.volume = targetVol;
                const ytVol = Math.round(targetVol * 100);
                const p = document.querySelector('ytmusic-player');
                if (p && p.playerApi) p.playerApi.setVolume(ytVol);
                const mp = document.getElementById('movie_player');
                if (mp && mp.setVolume) mp.setVolume(ytVol);
                setTimeout(() => { isEnforcingVolume = false; }, 50);
            }

            function waitForPlayerBar() {
                const playerBar = document.querySelector('ytmusic-player-bar');
                if (playerBar) {
                    setupObserver(playerBar);
                    setupVideoListeners();
                    return;
                }
                setTimeout(waitForPlayerBar, 500);
            }

            function setupVideoListeners() {
                // Watch for video element to attach play/pause listeners
                function attachVideoListeners() {
                    const video = document.querySelector('video');
                    if (!video) {
                        setTimeout(attachVideoListeners, 500);
                        return;
                    }
                    if (video.__kasetListenersAttached) return;
                    video.__kasetListenersAttached = true;

                    video.addEventListener('play', startPolling);
                    video.addEventListener('playing', startPolling);
                    // Enforce volume on playing event to catch all track changes
                    // (auto-advance, SPA navigation, button clicks)
                    video.addEventListener('playing', () => enforceVolumeNow());
                    video.addEventListener('pause', stopPolling);
                    video.addEventListener('ended', (event) => {
                        sendTrackEnded(event);
                        // Keep reporting for a beat: the page may advance its own queue into the next
                        // track, and that transition is exactly what the app has to see.
                        startTailPolling();
                        stopPolling();
                    });
                    video.addEventListener('waiting', () => sendUpdate()); // Buffer state
                    video.addEventListener('seeked', () => sendUpdate()); // Seek completed

                    // Volume enforcement: immediately revert external volume changes
                    // No debounce — the isEnforcingVolume flag prevents feedback loops.
                    // A debounce allowed YouTube's rapid-fire init events to keep pushing
                    // enforcement later, leaving wrong volume audible for 1-2 seconds.
                    video.addEventListener('volumechange', () => {
                        if (isEnforcingVolume) return;
                        if (window.__kasetIsSettingVolume) return;
                        enforceVolumeNow();
                    });

                    // Enforce volume at media lifecycle events where YouTube resets volume.
                    // YouTube's player often restores its stored volume at these points.
                    video.addEventListener('loadedmetadata', () => enforceVolumeNow());
                    video.addEventListener('loadeddata', () => enforceVolumeNow());
                    video.addEventListener('canplay', () => enforceVolumeNow());

                    // Rate enforcement: revert external rate changes (YouTube resets it on
                    // segment changes) and re-apply the podcast speed to new video elements.
                    video.addEventListener('ratechange', () => {
                        if (isEnforcingRate) return;
                        enforcePlaybackRateNow();
                    });
                    video.addEventListener('loadedmetadata', () => enforcePlaybackRateNow());
                    video.addEventListener('canplay', () => enforcePlaybackRateNow());

                    // Apply target volume immediately when video element is first detected
                    enforceVolumeNow();
                    enforcePlaybackRateNow();

                    // Startup enforcement burst: YouTube may reset volume up to ~2s after
                    // playback starts (via internal player init, quality switching, etc.).
                    // Enforce every 200ms for the first 3 seconds to catch delayed resets.
                    let burstCount = 0;
                    const burstInterval = setInterval(() => {
                        enforceVolumeNow();
                        if (++burstCount >= 15) clearInterval(burstInterval);
                    }, 200);

                    // Start polling if already playing
                    if (!video.paused) {
                        startPolling();
                    }
                }
                attachVideoListeners();

                // Also watch for video element replacement (YouTube may recreate it)
                const videoObserver = new MutationObserver(() => {
                    const video = document.querySelector('video');
                    if (video && !video.__kasetListenersAttached) {
                        attachVideoListeners();
                    }
                });
                videoObserver.observe(document.body, { childList: true, subtree: true });
            }

            function currentPlayerData() {
                const player = document.querySelector('ytmusic-player');
                if (player && player.playerApi && typeof player.playerApi.getVideoData === 'function') {
                    const data = player.playerApi.getVideoData();
                    if (data && typeof data === 'object') return data;
                }

                const moviePlayer = document.getElementById('movie_player');
                if (moviePlayer && typeof moviePlayer.getVideoData === 'function') {
                    const data = moviePlayer.getVideoData();
                    if (data && typeof data === 'object') return data;
                }

                return null;
            }

            function currentVideoId() {
                const playerData = currentPlayerData();
                if (playerData) {
                    const playerVideoId = playerData.video_id || playerData.videoId || '';
                    if (playerVideoId) return playerVideoId;
                }

                try {
                    const url = new URL(window.location.href);
                    return url.searchParams.get('v') || '';
                } catch (e) {
                    return '';
                }
            }

            function isAdPlaybackActive() {
                try {
                    const moviePlayer = document.getElementById('movie_player');
                    if (moviePlayer) {
                        if (moviePlayer.classList && moviePlayer.classList.contains('ad-showing')) return true;
                        if (typeof moviePlayer.getAdState === 'function' && moviePlayer.getAdState() === 1) return true;
                        if (typeof moviePlayer.isAdPlaying === 'function' && moviePlayer.isAdPlaying()) return true;
                    }

                    const playerData = currentPlayerData();
                    if (playerData && (playerData.isAd === true || playerData.adType)) {
                        return true;
                    }

                    const adContainer = document.querySelector('.video-ads, .ytp-ad-module, ytmusic-player-ads');
                    return !!adContainer;
                } catch (e) {
                    return false;
                }
            }

            function sendAdStateIfChanged(isAd) {
                if (lastAdState === isAd) return;
                lastAdState = isAd;
                bridge.postMessage({
                    type: 'AD_STATE',
                    isAd: isAd
                });
            }

            let lyricsPollId = null;
            window.startLyricsPoll = function() {
                if (lyricsPollId) return;
                const sendLyricsTime = () => {
                    const v = document.querySelector('video');
                    if (v) {
                        bridge.postMessage({
                            type: 'LYRICS_TIME',
                            time: v.currentTime
                        });
                    }
                };
                window.sendLyricsTime = sendLyricsTime;
                sendLyricsTime();
                lyricsPollId = setInterval(sendLyricsTime, 100);
            };

            window.sendLyricsTime = window.sendLyricsTime || function() {
                const v = document.querySelector('video');
                if (v) {
                    bridge.postMessage({ type: 'LYRICS_TIME', time: v.currentTime });
                }
            };

            window.stopLyricsPoll = function() {
                if (lyricsPollId) {
                    clearInterval(lyricsPollId);
                    lyricsPollId = null;
                }
            };

            function stopTailPolling() {
                if (tailPollId) {
                    clearInterval(tailPollId);
                    tailPollId = null;
                }
            }

            function startTailPolling() {
                if (tailPollId) return;
                let remaining = TAIL_POLL_TICKS;
                tailPollId = setInterval(() => {
                    sendUpdate();
                    if (--remaining <= 0) { stopTailPolling(); }
                }, TAIL_POLL_INTERVAL_MS);
            }

            function startPolling() {
                stopTailPolling();
                if (isPollingActive) return;
                isPollingActive = true;

                // Don't apply volume here - let volume enforcement handle it
                // Applying volume on every startPolling causes volume jumps

                sendUpdate(); // Immediate update
                // Poll at 1Hz during playback for progress updates (reduced CPU usage)
                pollIntervalId = setInterval(sendUpdate, POLL_INTERVAL_MS);
            }

            function stopPolling() {
                isPollingActive = false;
                if (pollIntervalId) {
                    clearInterval(pollIntervalId);
                    pollIntervalId = null;
                }
                sendUpdate(); // Final state update
            }

            function setupObserver(playerBar) {
                // Debounced mutation observer - only triggers on significant changes
                let mutationTimeout = null;
                const observer = new MutationObserver(() => {
                    if (mutationTimeout) return;
                    mutationTimeout = setTimeout(() => {
                        mutationTimeout = null;
                        sendUpdate();
                    }, 100);
                });
                observer.observe(playerBar, {
                    attributes: true, characterData: true,
                    childList: true, subtree: true,
                    attributeFilter: ['title', 'aria-label', 'like-status', 'value', 'aria-valuemax']
                });
                sendUpdate();
            }

            let lastEndedVideoId = '';
            let lastEndedAt = 0;
            function sendTrackEnded(event) {
                // The track that ended is the one the player still holds when the event fires; reporting
                // `lastVideoId` could name the next track if a state update won the race.
                const endedVideoId = currentVideoId() || lastVideoId;
                const now = Date.now();
                // One end per track: a second report for the same track within seconds would advance
                // Kaset's queue one row too far.
                if (endedVideoId && endedVideoId === lastEndedVideoId && now - lastEndedAt < 4000) {
                    return;
                }
                lastEndedVideoId = endedVideoId;
                lastEndedAt = now;

                // Where the media actually stopped. An end at the very start of the track is a load
                // the player did not honour (it kept the old position), not this track finishing, and
                // Kaset must not advance on it.
                let endedAt = 0;
                let endedDuration = 0;
                try {
                    const video = event && event.target ? event.target : document.querySelector('video');
                    endedAt = video && isFinite(video.currentTime) ? video.currentTime : 0;
                    endedDuration = video && isFinite(video.duration) ? video.duration : 0;
                } catch (error) {}

                bridge.postMessage({
                    type: 'TRACK_ENDED',
                    videoId: endedVideoId,
                    progress: endedAt,
                    duration: endedDuration
                });
            }

            function sendUpdate() {
                // Throttle updates
                const now = Date.now();
                if (now - lastUpdateTime < UPDATE_THROTTLE_MS && isPollingActive) {
                    return;
                }
                lastUpdateTime = now;

                try {
                    // Keep the podcast speed applied as YouTube swaps video elements.
                    enforcePlaybackRateNow();

                    // Use video element's paused property for language-agnostic detection
                    // Previously checked button title/aria-label which fails for non-English locales
                    const video = document.querySelector('video');
                    const isPlaying = video ? !video.paused : false;

                    const progressBar = document.querySelector('#progress-bar');

                    // The track the player bar itself is describing. It lags an in-page track swap:
                    // its text then belongs to the previous track while the player already plays the
                    // new one, and Swift must not record another song's title and artist for this one.
                    function playerBarVideoId() {
                        try {
                            const bar = document.querySelector('ytmusic-player-bar');
                            if (!bar) return '';
                            const link = bar.querySelector('a[href*="v="]');
                            if (!link) return '';
                            return new URL(link.href, window.location.href).searchParams.get('v') || '';
                        } catch (error) {
                            return '';
                        }
                    }

                    // Extract track metadata
                    const titleEl = document.querySelector('.ytmusic-player-bar.title');
                    const artistEl = document.querySelector('.ytmusic-player-bar.byline');
                    const thumbEl = document.querySelector('.ytmusic-player-bar .thumbnail img, ytmusic-player-bar .image');

                    const playerData = currentPlayerData();
                    const playerTitle = playerData && typeof playerData.title === 'string'
                        ? playerData.title.trim()
                        : '';
                    const playerArtist = playerData && typeof playerData.author === 'string'
                        ? playerData.author.trim()
                        : '';

                    let title = titleEl ? titleEl.textContent.trim() : '';
                    let artist = artistEl ? artistEl.textContent.trim() : '';
                    const videoId = currentVideoId();
                    let thumbnailUrl = '';

                    // Prefer player API metadata when the DOM appears to be lagging behind the actual video.
                    //
                    // The player API describes the video it holds, so its text is the freshest thing the
                    // page has after an in-page swap — unlike the bar's DOM, which can still be showing
                    // the previous song. `metadataFromPlayer` says which source won, so Swift can tell
                    // "a stale bar" (keep what it has) from "the player's own words" (believe them).
                    let metadataFromPlayer = false;
                    if (playerTitle && title && playerTitle !== title) {
                        title = playerTitle;
                        if (playerArtist) artist = playerArtist;
                        metadataFromPlayer = true;
                    } else {
                        if (!title && playerTitle) { title = playerTitle; metadataFromPlayer = true; }
                        if (!artist && playerArtist) { artist = playerArtist; metadataFromPlayer = true; }
                    }

                    // Get the thumbnail URL from the image element
                    if (thumbEl) {
                        thumbnailUrl = thumbEl.src || thumbEl.getAttribute('src') || '';
                    }

                    // Extract like status from the like button renderer
                    let likeStatus = 'INDIFFERENT';
                    const likeRenderer = document.querySelector('ytmusic-like-button-renderer');
                    if (likeRenderer) {
                        const status = likeRenderer.getAttribute('like-status');
                        if (status === 'LIKE') likeStatus = 'LIKE';
                        else if (status === 'DISLIKE') likeStatus = 'DISLIKE';
                    }

                    const isAd = isAdPlaybackActive();
                    sendAdStateIfChanged(isAd);

                    // Check if track changed
                    const metadataChanged = title !== '' && (title !== lastTitle || artist !== lastArtist);
                    const videoIdChanged = videoId !== '' && videoId !== lastVideoId;
                    const trackChanged = metadataChanged || videoIdChanged;
                    if (trackChanged) {
                        if (title !== '') {
                            lastTitle = title;
                            lastArtist = artist;
                        }
                        if (videoId !== '') {
                            lastVideoId = videoId;
                        }
                    }

                    // Detect if actual video content is available
                    // This is a quick DOM check for initial detection.
                    // The API-based musicVideoType detection in fetchSongMetadata
                    // will provide the authoritative value once metadata is loaded.
                    let hasVideo = false;

                    // Quick check: Look for Song/Video toggle buttons
                    const toggleButtons = document.querySelectorAll('tp-yt-paper-button, button, [role="button"]');
                    for (const btn of toggleButtons) {
                        const text = (btn.textContent || btn.innerText || '').trim().toLowerCase();
                        if (text === 'video' || text === 'song') {
                            hasVideo = true;
                            break;
                        }
                    }

                    // The media element is the authority on the track that is loaded and on how long it
                    // is; the progress bar's DOM attributes lag an in-page swap and would hand Kaset the
                    // previous track's length (which the lyrics search uses to tell versions apart).
                    const mediaDuration = video && isFinite(video.duration) && video.duration > 0
                        ? Math.round(video.duration)
                        : 0;
                    const mediaProgress = video && isFinite(video.currentTime)
                        ? Math.round(video.currentTime)
                        : 0;
                    const barProgress = progressBar ? parseInt(progressBar.getAttribute('value') || '0') : 0;
                    const barDuration = progressBar ? parseInt(progressBar.getAttribute('aria-valuemax') || '0') : 0;

                    bridge.postMessage({
                        type: 'STATE_UPDATE',
                        isPlaying: isPlaying,
                        progress: mediaDuration > 0 ? mediaProgress : barProgress,
                        duration: mediaDuration > 0 ? mediaDuration : barDuration,
                        metadataFromPlayer: metadataFromPlayer,
                        title: title,
                        artist: artist,
                        videoId: videoId,
                        barVideoId: playerBarVideoId(),
                        thumbnailUrl: thumbnailUrl,
                        trackChanged: trackChanged,
                        likeStatus: likeStatus,
                        hasVideo: hasVideo,
                        isAd: isAd,
                        videoWidth: video ? (video.videoWidth || 0) : 0,
                        videoHeight: video ? (video.videoHeight || 0) : 0
                    });
                } catch (e) {}
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', waitForPlayerBar);
            } else {
                waitForPlayerBar();
            }
        })();
        """
    }
}
