import Foundation
import JavaScriptCore
import Testing
@testable import Kaset

/// Tests for the media-session metadata pin that keeps the system's Now Playing panel on Kaset's track.
@Suite(.serialized, .tags(.service))
@MainActor
struct NowPlayingMetadataTests {
    @Test("The panel describes the playing track, with its own artwork")
    func metadataDescribesTheSong() throws {
        let song = Song(
            id: "LPVBLA8Kedk",
            title: "Lights",
            artists: [Artist(id: "a1", name: "Ellie Goulding")],
            album: Album(
                id: "MPRE1",
                title: "An Introduction To Ellie Goulding EP",
                artists: nil,
                thumbnailURL: nil,
                year: nil,
                trackCount: nil
            ),
            thumbnailURL: URL(string: "https://example.com/lights.jpg"),
            videoId: "LPVBLA8Kedk"
        )

        guard let metadata = WebNowPlayingMetadata(song: song) else {
            Issue.record("A song with a real title should be published")
            return
        }
        #expect(metadata.title == "Lights")
        #expect(metadata.artist == "Ellie Goulding")
        #expect(metadata.album == "An Introduction To Ellie Goulding EP")
        #expect(metadata.artworkURL?.absoluteString == "https://example.com/lights.jpg")
    }

    @Test("The Loading placeholder is never published as a song")
    func placeholderIsNotPublished() {
        let song = Song(id: "v1", title: "Loading...", artists: [], videoId: "v1")
        #expect(WebNowPlayingMetadata(song: song) == nil)

        let empty = Song(id: "v2", title: " ", artists: [Artist(id: "a", name: "Someone")], videoId: "v2")
        #expect(WebNowPlayingMetadata(song: empty) == nil)
    }

    @Test("Artwork sources that cannot be loaded are published as no artwork")
    func artworkIsOnlyPublishedWhenItCanBeFetched() {
        #expect(
            WebNowPlayingMetadata.absoluteArtworkURL(URL(string: "//example.com/a.jpg"))?.absoluteString
                == "https://example.com/a.jpg"
        )
        #expect(WebNowPlayingMetadata.absoluteArtworkURL(URL(string: "data:image/png;base64,AA==")) == nil)
    }

    @Test("The page cannot overwrite the pinned track's metadata")
    func pageCannotOverwritePinnedMetadata() throws {
        let context = try #require(self.makeContext())
        self.evaluate(SingletonPlayerWebView.nowPlayingMetadataScript, in: context)

        try self.push(title: "Lights", artist: "Ellie Goulding", in: context)

        // What YouTube Music does on the next playback event: describe its own idea of the song.
        self.evaluate("""
            navigator.mediaSession.metadata =
                new MediaMetadata({ title: 'Hello (triple j Like A Version)', artist: 'daine' });
        """, in: context)

        #expect(self.nativeMetadataValue("title", in: context) == "Lights")
        #expect(self.nativeMetadataValue("artist", in: context) == "Ellie Goulding")
        #expect(context.evaluateScript("navigator.mediaSession.metadata.title")?.toString() == "Lights")
    }

    @Test("The artwork is Kaset's, so the panel cannot show another song's picture")
    func artworkComesFromKaset() throws {
        let context = try #require(self.makeContext())
        self.evaluate(SingletonPlayerWebView.nowPlayingMetadataScript, in: context)

        self.evaluate("""
            navigator.mediaSession.metadata =
                new MediaMetadata({ title: 'Something Else', artwork: [{ src: 'https://example.com/wrong.jpg' }] });
        """, in: context)

        try self.push(
            title: "Lights",
            artist: "Ellie Goulding",
            artwork: "https://example.com/lights.jpg",
            in: context
        )

        #expect(self.nativeMetadataValue("artworkSrc", in: context) == "https://example.com/lights.jpg")
    }

    @Test("A track change replaces the whole description")
    func trackChangeReplacesTheDescription() throws {
        let context = try #require(self.makeContext())
        self.evaluate(SingletonPlayerWebView.nowPlayingMetadataScript, in: context)

        try self.push(title: "Lights", artist: "Ellie Goulding", in: context)
        try self.push(title: "Titanium", artist: "David Guetta, Sia", in: context)

        #expect(self.nativeMetadataValue("title", in: context) == "Titanium")
        #expect(self.nativeMetadataValue("artist", in: context) == "David Guetta, Sia")
    }

    @Test("Nothing playing gives the panel back to the page")
    func clearingReleasesThePin() throws {
        let context = try #require(self.makeContext())
        self.evaluate(SingletonPlayerWebView.nowPlayingMetadataScript, in: context)

        try self.push(title: "Lights", artist: "Ellie Goulding", in: context)
        self.evaluate(SingletonPlayerWebView.nowPlayingMetadataClearScript, in: context)

        self.evaluate("""
            navigator.mediaSession.metadata = new MediaMetadata({ title: 'Page Track' });
        """, in: context)

        #expect(self.nativeMetadataValue("title", in: context) == "Page Track")
    }

    @Test("A replaced media session object is still the one Kaset writes")
    func replacedSessionStillTakesKasetMetadata() throws {
        let context = try #require(self.makeContext())
        self.evaluate(SingletonPlayerWebView.nowPlayingMetadataScript, in: context)

        try self.push(title: "Lights", artist: "Ellie Goulding", in: context)

        // Some pages recreate the session rather than reusing it.
        self.evaluate("navigator.mediaSession = Object.create(MediaSession.prototype);", in: context)

        try self.push(title: "Titanium", artist: "David Guetta, Sia", in: context)
        #expect(self.nativeMetadataValue("title", in: context) == "Titanium")
    }

    @Test("A page without a media session is not an error")
    func missingMediaSessionIsSilent() throws {
        let context = try #require(JSContext())
        self.evaluate("var navigator = {}; var window = {};", in: context)

        self.evaluate(SingletonPlayerWebView.nowPlayingMetadataScript, in: context)

        // Nothing to pin yet, and nothing to throw: the value is assigned when a session appears.
        let status = context.evaluateScript("""
            window.__kasetNowPlaying.set({ title: 'Lights', artist: 'Ellie Goulding' })
        """)?.toString()
        #expect(status == "assigned")

        let cleared = context.evaluateScript("window.__kasetNowPlaying.clear()")?.toString()
        #expect(cleared == "cleared")
    }

    // MARK: - Helpers

    @discardableResult
    private func push(
        title: String,
        artist: String,
        artwork: String? = nil,
        in context: JSContext
    ) throws -> String? {
        let song = Song(
            id: "LPVBLA8Kedk",
            title: title,
            artists: [Artist(id: "a1", name: artist)],
            thumbnailURL: artwork.flatMap(URL.init(string:)),
            videoId: "LPVBLA8Kedk"
        )
        let metadata = try #require(WebNowPlayingMetadata(song: song))
        self.evaluate(SingletonPlayerWebView.nowPlayingMetadataSetScript(metadata), in: context)
        return self.nativeMetadataValue("title", in: context)
    }

    private func nativeMetadataValue(_ property: String, in context: JSContext) -> String? {
        context.evaluateScript("nativeMetadata ? String(nativeMetadata.\(property)) : null")?.toString()
    }

    /// A page whose `MediaSession.prototype.metadata` is a real accessor, like WebKit's.
    private func makeContext() -> JSContext? {
        guard let context = JSContext() else { return nil }

        self.evaluate(
            """
            var nativeMetadata = null;
            var nativeWrites = [];
            function MediaMetadata(init) {
                init = init || {};
                this.title = init.title || '';
                this.artist = init.artist || '';
                this.album = init.album || '';
                this.artwork = init.artwork || [];
                this.artworkSrc = this.artwork.length > 0 ? this.artwork[0].src : '';
            }
            function MediaSession() {}
            Object.defineProperty(MediaSession.prototype, 'metadata', {
                configurable: true,
                enumerable: true,
                get: function() { return nativeMetadata; },
                set: function(value) {
                    nativeMetadata = value;
                    nativeWrites.push(value);
                }
            });
            var mediaSession = Object.create(MediaSession.prototype);
            var navigator = { mediaSession: mediaSession };
            var window = {};
            """,
            in: context
        )

        return context
    }

    private func evaluate(_ script: String, in context: JSContext) {
        context.exception = nil
        _ = context.evaluateScript(script)

        if let exception = context.exception?.toString() {
            Issue.record("JavaScript exception: \(exception)")
        }
    }
}
