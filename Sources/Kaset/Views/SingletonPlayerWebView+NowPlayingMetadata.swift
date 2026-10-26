import Foundation

// MARK: - SingletonPlayerWebView Now Playing Metadata

/// What the system's Now Playing panel describes.
///
/// macOS takes that panel from the WebView's media session — Kaset sets no `MPNowPlayingInfoCenter`
/// of its own — so without this the panel shows whatever YouTube Music last wrote there. With the
/// page playing Kaset's tracks that is the page's own idea of the song, which lags a track change and
/// can carry another item's artwork; the panel was wrong for the whole song and correct only for the
/// moment it changed.
struct WebNowPlayingMetadata: Equatable {
    let title: String
    let artist: String
    let album: String?
    let artworkURL: URL?

    /// The metadata for `song`, or `nil` while the track is only a placeholder.
    ///
    /// A start seeds `currentTrack` with "Loading..."; publishing that to the system panel would put a
    /// placeholder where the previous song's name belongs, so nothing is published until there is a
    /// real title.
    init?(song: Song) {
        let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != "Loading..." else { return nil }
        self.title = title
        self.artist = song.artistsDisplay
        self.album = song.album?.title
        self.artworkURL = Self.absoluteArtworkURL(song.thumbnailURL)
    }

    /// An artwork URL the media session can fetch: `//host/...` is made absolute, and anything that is
    /// not http(s) is dropped rather than published as a source it cannot load.
    static func absoluteArtworkURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        if url.scheme == nil, url.absoluteString.hasPrefix("//") {
            return URL(string: "https:" + url.absoluteString)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}

extension SingletonPlayerWebView {
    /// Pins the media session's metadata to Kaset's track.
    ///
    /// Installed at document start, before YouTube Music's own scripts, because the page writes
    /// `navigator.mediaSession.metadata` itself — on playback events and again as its UI settles, which
    /// is what replaced the right song with the wrong one. Installing first lets the property be
    /// wrapped, so a push from Kaset is the last word and the page's later writes are dropped.
    ///
    /// Feature-detected and no-throw throughout: where `metadata` cannot be wrapped the push still
    /// assigns the value (the panel is then right at the moment of the push), and a page without a
    /// media session at all simply gets nothing.
    static var nowPlayingMetadataScript: String {
        """
        (function() {
            'use strict';
            if (window.__kasetNowPlaying) { return; }

            var state = { pinned: false, value: null };
            var session = null;
            var original = null;

            function mediaSession() {
                try { return navigator.mediaSession || null; } catch (error) { return null; }
            }

            function nativeSet(value) {
                if (!session || !original) { return false; }
                try {
                    original.set.call(session, value);
                    return true;
                } catch (error) {
                    return false;
                }
            }

            // WebKit exposes `metadata` as an accessor on `MediaSession.prototype`; an engine that
            // defines it on the instance instead is handled the same way by walking the chain.
            function metadataAccessor(ms) {
                var owner = ms;
                while (owner) {
                    var candidate = Object.getOwnPropertyDescriptor(owner, 'metadata');
                    if (candidate &&
                        typeof candidate.get === 'function' &&
                        typeof candidate.set === 'function') {
                        return { owner: owner, descriptor: candidate };
                    }
                    owner = Object.getPrototypeOf(owner);
                }
                return null;
            }

            function install() {
                var ms = mediaSession();
                if (!ms) { return false; }
                try {
                    var accessor = metadataAccessor(ms);
                    if (!accessor) { return false; }
                    // Already wrapped: a page that swapped in a new session object still writes through
                    // the same wrapped accessor, so only the object being written to has to change.
                    if (accessor.owner.__kasetMetadataPinned) {
                        session = ms;
                        return original !== null;
                    }
                    var descriptor = accessor.descriptor;
                    original = descriptor;
                    Object.defineProperty(accessor.owner, 'metadata', {
                        configurable: true,
                        enumerable: descriptor.enumerable,
                        get: function() {
                            if (state.pinned && state.value) { return state.value; }
                            return original.get.call(this);
                        },
                        set: function(value) {
                            // Kaset's queue is what the panel describes; the page's own description of
                            // the same moment is exactly what was wrong.
                            if (state.pinned) { return; }
                            original.set.call(this, value);
                        }
                    });
                    accessor.owner.__kasetMetadataPinned = true;
                    session = ms;
                    return true;
                } catch (error) {
                    return false;
                }
            }

            function materialize(payload) {
                var data = payload || {};
                var artwork = [];
                if (data.artwork) {
                    artwork.push({ src: data.artwork, sizes: '512x512' });
                }
                try {
                    return new MediaMetadata({
                        title: data.title || '',
                        artist: data.artist || '',
                        album: data.album || '',
                        artwork: artwork
                    });
                } catch (error) {
                    return {
                        title: data.title || '',
                        artist: data.artist || '',
                        album: data.album || '',
                        artwork: artwork
                    };
                }
            }

            window.__kasetNowPlaying = {
                set: function(payload) {
                    install();
                    var value = materialize(payload);
                    state.pinned = true;
                    state.value = value;
                    // The page's own slot is what the system reads, so the pinned value is pushed into
                    // it rather than only being returned by the wrapping getter.
                    if (nativeSet(value)) { return 'applied'; }
                    try {
                        var ms = mediaSession();
                        if (ms) { ms.metadata = value; }
                        return 'assigned';
                    } catch (error) {
                        return 'error';
                    }
                },
                clear: function() {
                    state.pinned = false;
                    state.value = null;
                    nativeSet(null);
                    return 'cleared';
                },
                isPinned: function() { return state.pinned; }
            };

            install();
        })();
        """
    }

    /// Builds the call that hands `metadata` to the pinned media session.
    static func nowPlayingMetadataSetScript(_ metadata: WebNowPlayingMetadata) -> String {
        var payload: [String: String] = [
            "title": metadata.title,
            "artist": metadata.artist,
        ]
        if let album = metadata.album {
            payload["album"] = album
        }
        if let artworkURL = metadata.artworkURL {
            payload["artwork"] = artworkURL.absoluteString
        }

        let json: String = if let data = try? JSONSerialization.data(withJSONObject: payload),
                              let encoded = String(data: data, encoding: .utf8)
        {
            encoded
        } else {
            "{}"
        }

        return """
        (function() {
            var api = window.__kasetNowPlaying;
            if (!api) { return 'not-installed'; }
            try { return api.set(\(json)); } catch (error) { return 'error'; }
        })();
        """
    }

    /// Builds the call that gives the media session back to the page (nothing playing).
    static var nowPlayingMetadataClearScript: String {
        """
        (function() {
            var api = window.__kasetNowPlaying;
            if (!api) { return 'not-installed'; }
            try { return api.clear(); } catch (error) { return 'error'; }
        })();
        """
    }

    /// Describes `metadata` as the system's Now Playing entry.
    ///
    /// The page answers `applied` when the session is pinned and taken, or `assigned` when only the
    /// value could be written (no accessor to wrap) — the difference between the panel staying on this
    /// track and the page being able to replace it again.
    func applyNowPlayingMetadata(_ metadata: WebNowPlayingMetadata) {
        guard let webView else { return }
        webView.evaluateJavaScript(Self.nowPlayingMetadataSetScript(metadata)) { result, error in
            if let error {
                self.logger.error("Now Playing metadata push failed: \(error.localizedDescription)")
            } else if let status = result as? String {
                self.logger.debug(
                    "Now Playing '\(metadata.title, privacy: .public)' by '\(metadata.artist, privacy: .public)': \(status, privacy: .public)"
                )
            }
        }
    }

    /// Clears the system's Now Playing entry.
    func clearNowPlayingMetadata() {
        guard let webView else { return }
        webView.evaluateJavaScript(Self.nowPlayingMetadataClearScript, completionHandler: nil)
    }
}
