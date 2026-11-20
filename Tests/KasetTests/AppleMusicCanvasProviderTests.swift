import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service))
struct AppleMusicCanvasProviderTests {
    // MARK: - Motion video extraction

    @Test("videoURL prefers motionDetailRaw, then falls back to any nested video")
    func videoURLPreferenceAndFallback() {
        let data: [String: Any] = [
            "motionDetailRaw": ["video": "https://example.com/raw.m3u8"],
            "motionDetailSquare": ["video": "https://example.com/square.m3u8"],
        ]
        #expect(AppleMusicCanvasProvider.videoURL(in: data)?.absoluteString == "https://example.com/raw.m3u8")

        let onlyFallback: [String: Any] = ["someCustomKey": ["video": "https://example.com/custom.m3u8"]]
        #expect(AppleMusicCanvasProvider.videoURL(in: onlyFallback)?.absoluteString == "https://example.com/custom.m3u8")

        #expect(AppleMusicCanvasProvider.videoURL(in: [:]) == nil)
        #expect(AppleMusicCanvasProvider.videoURL(in: ["motionDetailRaw": ["video": ""]]) == nil)
    }

    @Test("extractEditorialVideoURL prefers editorialVideo over editorialArtwork")
    func prefersEditorialVideo() {
        let attributes: [String: Any] = [
            "editorialVideo": ["motionDetailTall": ["video": "https://example.com/video.m3u8"]],
            "editorialArtwork": ["motionDetailTall": ["video": "https://example.com/artwork.m3u8"]],
        ]
        #expect(
            AppleMusicCanvasProvider.extractEditorialVideoURL(from: attributes)?.absoluteString
                == "https://example.com/video.m3u8"
        )
    }

    @Test("extractEditorialVideoURL falls back to editorialArtwork")
    func fallsBackToEditorialArtwork() {
        let attributes: [String: Any] = [
            "editorialArtwork": ["motionSquareVideo1x1": ["video": "https://example.com/artwork.m3u8"]],
        ]
        #expect(
            AppleMusicCanvasProvider.extractEditorialVideoURL(from: attributes)?.absoluteString
                == "https://example.com/artwork.m3u8"
        )
        #expect(AppleMusicCanvasProvider.extractEditorialVideoURL(from: [:]) == nil)
    }

    // MARK: - Album selection

    @Test("albumSearchResults reads the catalog search shape")
    func parsesAlbumSearchResults() {
        let json: [String: Any] = [
            "results": ["albums": ["data": [
                ["id": "123", "attributes": ["name": "Old Album", "artistName": "The Artist"]],
                ["id": "456", "attributes": ["name": "Unknown Artist Album"]],
                ["attributes": ["name": "No ID"]],
            ]]],
        ]
        let results = AppleMusicCanvasProvider.albumSearchResults(from: json)
        #expect(results.map(\.id) == ["123", "456"])
        #expect(results.first?.artistName == "The Artist")
        #expect(results.last?.artistName == "")
        #expect(AppleMusicCanvasProvider.albumSearchResults(from: [:]).isEmpty)
    }

    /// Regression: the newest album's canvas was painted over old songs that are not
    /// on it, because the provider read the *artist* resource's motion artwork.
    @Test("only the reported album and a release titled after the song are candidates")
    func candidatesExcludeOtherAlbums() {
        let results = [
            AppleMusicCanvasProvider.AlbumSearchResult(id: "newest", name: "Newest Album", artistName: "The Artist"),
            AppleMusicCanvasProvider.AlbumSearchResult(id: "old", name: "Old Album", artistName: "The Artist"),
            AppleMusicCanvasProvider.AlbumSearchResult(id: "single", name: "Old Song", artistName: "The Artist"),
            AppleMusicCanvasProvider.AlbumSearchResult(id: "other", name: "Old Album", artistName: "Someone Else"),
        ]
        let candidates = AppleMusicCanvasProvider.albumCandidates(
            from: results,
            song: "Old Song",
            artist: "The Artist",
            album: "Old Album"
        )
        #expect(candidates.map(\.id) == ["old", "single"])
    }

    @Test("the reported album ranks ahead of a release titled after the song")
    func reportedAlbumRanksFirst() {
        let results = [
            AppleMusicCanvasProvider.AlbumSearchResult(id: "single", name: "Old Song", artistName: "The Artist"),
            AppleMusicCanvasProvider.AlbumSearchResult(id: "old", name: "Old Album", artistName: "The Artist"),
        ]
        let candidates = AppleMusicCanvasProvider.albumCandidates(
            from: results,
            song: "Old Song",
            artist: "The Artist",
            album: "Old Album"
        )
        #expect(candidates.map(\.id) == ["old", "single"])
    }

    @Test("a single's `- Single` / `- EP` title suffix is tolerated, nothing else is")
    func singleSuffixIsTolerated() {
        #expect(AppleMusicCanvasProvider.albumRank("Good Days - Single", song: "Good Days", album: "") == 1)
        #expect(AppleMusicCanvasProvider.albumRank("Good Days - EP", song: "Good Days", album: "") == 1)
        #expect(AppleMusicCanvasProvider.albumRank("SOS Deluxe: LANA", song: "Good Days", album: "SOS") == nil)
        #expect(AppleMusicCanvasProvider.albumRank("Greatest Hits", song: "Good Days", album: "SOS") == nil)
    }

    // MARK: - Song record

    @Test("songSearchResults reads the catalog search shape")
    func parsesSongSearchResults() {
        let json: [String: Any] = [
            "results": ["songs": ["data": [
                ["id": "1674691586", "attributes": [
                    "name": "Flowers",
                    "artistName": "Miley Cyrus",
                    "url": "https://music.apple.com/at/album/flowers/1674691585?i=1674691586",
                ]],
                ["attributes": ["name": "No ID"]],
            ]]],
        ]
        let results = AppleMusicCanvasProvider.songSearchResults(from: json)
        #expect(results.count == 1)
        #expect(results.first?.artistName == "Miley Cyrus")
        #expect(AppleMusicCanvasProvider.albumId(fromSongURL: results.first?.url) == "1674691585")
        #expect(AppleMusicCanvasProvider.songSearchResults(from: [:]).isEmpty)
    }

    @Test("albumId reads the album id out of a song URL")
    func albumIdFromSongURL() {
        #expect(
            AppleMusicCanvasProvider.albumId(
                fromSongURL: URL(string: "https://music.apple.com/at/album/flowers/1674691585?i=1674691586")
            ) == "1674691585"
        )
        #expect(AppleMusicCanvasProvider.albumId(fromSongURL: URL(string: "https://music.apple.com/at/song/123")) == nil)
        #expect(AppleMusicCanvasProvider.albumId(fromSongURL: nil) == nil)
    }

    /// The album is discovered from Apple's record of the *song*, whose URL links the
    /// album. Album search is storefront-dependent ("Drake Jimmy Cooks" in the
    /// Austrian storefront returns unrelated singles instead of the album) and YouTube
    /// reports a single as the album, so neither can name it.
    @Test("every album the song record names is a candidate, in search order")
    func albumIdsFromSongRecords() {
        let songs = [
            AppleMusicCanvasProvider.SongSearchResult(
                id: "1630221907",
                name: "Jimmy Cooks (feat. 21 Savage)",
                artistName: "Drake",
                url: URL(string: "https://music.apple.com/at/album/jimmy-cooks-feat-21-savage/1630221591?i=1630221907")
            ),
            AppleMusicCanvasProvider.SongSearchResult(
                id: "1630231297",
                name: "Jimmy Cooks (feat. 21 Savage)",
                artistName: "Drake",
                url: URL(string: "https://music.apple.com/at/album/jimmy-cooks-feat-21-savage/1630230040?i=1630231297")
            ),
            AppleMusicCanvasProvider.SongSearchResult(
                id: "99",
                name: "Jimmy Cooks (Mixed)",
                artistName: "Apple Music Resident DJ",
                url: URL(string: "https://music.apple.com/at/album/rap-vol-2/1680967836")
            ),
        ]
        #expect(
            AppleMusicCanvasProvider.albumIds(from: songs, song: "Jimmy Cooks", artist: "Drake, 21 Savage")
                == ["1630221591", "1630230040"]
        )
    }

    @Test("the album comes from the song record, not from the reported album name")
    func albumComesFromSongRecord() {
        let songs = [
            AppleMusicCanvasProvider.SongSearchResult(
                id: "1674691586",
                name: "Flowers",
                artistName: "Miley Cyrus",
                url: URL(string: "https://music.apple.com/at/album/flowers/1674691585?i=1674691586")
            ),
        ]
        // YouTube reports "Flowers" — the single — as the album; Apple's record links
        // the album the track is actually on.
        #expect(
            AppleMusicCanvasProvider.albumIds(from: songs, song: "Flowers", artist: "Miley Cyrus")
                == ["1674691585"]
        )
    }

    @Test("artist matching accepts any shared credit")
    func artistMatching() {
        #expect(AppleMusicCanvasProvider.artistMatches(validation: "The Artist", returned: "The Artist"))
        #expect(AppleMusicCanvasProvider.artistMatches(validation: "Drake, 21 Savage", returned: "Drake & 21 Savage"))
        // The album names the release's lead artist only.
        #expect(AppleMusicCanvasProvider.artistMatches(validation: "Drake, 21 Savage", returned: "Drake"))
        #expect(AppleMusicCanvasProvider.artistMatches(validation: "Drake, 21 Savage", returned: "21 Savage"))
        #expect(AppleMusicCanvasProvider.artistMatches(validation: "The Artist", returned: "Someone Else") == false)
        // No artist constraint was asked for.
        #expect(AppleMusicCanvasProvider.artistMatches(validation: "", returned: "Anyone"))
    }

    /// Regression: every collaboration was dropped, because its track credits name
    /// more artists than the album those credits belong to.
    @Test("a collaboration matches the album credited to its lead artist")
    func collaborationMatchesLeadArtist() {
        let results = [
            AppleMusicCanvasProvider.AlbumSearchResult(id: "newest", name: "For All The Dogs", artistName: "Drake"),
            AppleMusicCanvasProvider.AlbumSearchResult(id: "album", name: "Honestly, Nevermind", artistName: "Drake"),
        ]
        let candidates = AppleMusicCanvasProvider.albumCandidates(
            from: results,
            song: "Jimmy Cooks",
            artist: "Drake, 21 Savage",
            album: "Honestly, Nevermind"
        )
        #expect(candidates.map(\.id) == ["album"])
    }

    // MARK: - Album verification

    @Test("artwork is refused unless the album's track list holds the song")
    func artworkRequiresTheSongOnTheAlbum() {
        let album = Self.makeAlbumResource(name: "Old Album", tracks: ["Another Song", "Old Song"])
        let artwork = AppleMusicCanvasProvider.artwork(fromAlbum: album, song: "Old Song")
        #expect(artwork?.albumName == "Old Album")
        #expect(artwork?.videoURL.absoluteString == "https://example.com/old.m3u8")

        #expect(AppleMusicCanvasProvider.artwork(fromAlbum: album, song: "New Song") == nil)
        #expect(AppleMusicCanvasProvider.artwork(fromAlbum: album, song: "   ") == nil)
    }

    /// Regression: Apple's own track listing carries the featured credit
    /// ("Jimmy Cooks (feat. 21 Savage)"), so requiring the bare title rejected every
    /// collaboration even after the artist check was relaxed.
    @Test("a feature-decorated track title still verifies")
    func featureDecoratedTrackTitleVerifies() {
        #expect(AppleMusicCanvasProvider.trackTitleMatches("Jimmy Cooks (feat. 21 Savage)", "Jimmy Cooks"))
        #expect(AppleMusicCanvasProvider.trackTitleMatches("Jimmy Cooks", "Jimmy Cooks (feat. 21 Savage)"))
        #expect(AppleMusicCanvasProvider.trackTitleMatches("Jimmy Cooks feat. 21 Savage", "Jimmy Cooks"))
        #expect(AppleMusicCanvasProvider.trackTitleMatches("Jimmy Cooks", "Jimmy Cooks"))
        // A word inside a title is not a credit.
        #expect(AppleMusicCanvasProvider.trackTitleMatches("Dance With Me", "Dance") == false)
        #expect(AppleMusicCanvasProvider.trackTitleMatches("Jimmy Cooks (feat. 21 Savage)", "Jimmy Cooks 2") == false)
        #expect(AppleMusicCanvasProvider.trackTitleMatches("Jimmy Cooks", "   ") == false)

        let album = Self.makeAlbumResource(name: "Honestly, Nevermind", tracks: ["Jimmy Cooks (feat. 21 Savage)"])
        #expect(AppleMusicCanvasProvider.artwork(fromAlbum: album, song: "Jimmy Cooks") != nil)
    }

    @Test("artwork is nil when the album carries no motion video")
    func artworkRequiresMotionVideo() {
        let album = Self.makeAlbumResource(name: "Old Album", tracks: ["Old Song"], video: nil)
        #expect(AppleMusicCanvasProvider.artwork(fromAlbum: album, song: "Old Song") == nil)
    }

    // MARK: - Token handling

    @Test("decodeBase64URL handles the JWT-safe alphabet")
    func decodesBase64URL() {
        let payload = Data(#"{"iss":"apple.com"}"#.utf8).base64EncodedString()
        let jwtSafe = payload
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let decoded = AppleMusicCanvasProvider.decodeBase64URL(jwtSafe)
        #expect(decoded != nil)
        #expect(String(data: decoded!, encoding: .utf8) == #"{"iss":"apple.com"}"#)
    }

    @Test("validateToken accepts an unexpired token with iss and exp claims")
    func validatesUnexpiredToken() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let exp = Int(nowMs / 1000) + 3_600 // +1 hour, in seconds (JWT convention)
        let token = Self.makeToken(payload: #"{"iss":"AMPWebPlay","exp":\#(exp)}"#)
        let discovered = AppleMusicCanvasProvider.validateToken(token, nowMs: nowMs)
        #expect(discovered?.token == token)
        #expect(discovered?.expiryMs == Int64(exp) * 1000)
    }

    @Test("validateToken rejects expired, iss-less, and malformed tokens")
    func rejectsInvalidTokens() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let nowSeconds = Int(nowMs / 1000)

        // Expired (exp in seconds).
        let expired = Self.makeToken(payload: #"{"iss":"AMPWebPlay","exp":\#(nowSeconds - 3_600)}"#)
        #expect(AppleMusicCanvasProvider.validateToken(expired, nowMs: nowMs) == nil)

        // Missing iss.
        let noIss = Self.makeToken(payload: #"{"exp":\#(nowSeconds + 3_600)}"#)
        #expect(AppleMusicCanvasProvider.validateToken(noIss, nowMs: nowMs) == nil)

        // Missing exp.
        let noExp = Self.makeToken(payload: #"{"iss":"AMPWebPlay"}"#)
        #expect(AppleMusicCanvasProvider.validateToken(noExp, nowMs: nowMs) == nil)

        // Not a JWT.
        #expect(AppleMusicCanvasProvider.validateToken("not-a-token", nowMs: nowMs) == nil)
        #expect(AppleMusicCanvasProvider.validateToken("a.b", nowMs: nowMs) == nil)
    }

    // MARK: - Helpers

    /// An album resource shaped like `GET /v1/catalog/{storefront}/albums/{id}` with
    /// `extend=editorialVideo` and `include=tracks`.
    private static func makeAlbumResource(
        name: String,
        tracks: [String],
        video: String? = "https://example.com/old.m3u8"
    ) -> [String: Any] {
        var attributes: [String: Any] = ["name": name, "artistName": "The Artist"]
        if let video {
            attributes["editorialVideo"] = ["motionDetailSquare": ["video": video]]
        }
        return [
            "id": "old",
            "attributes": attributes,
            "relationships": ["tracks": ["data": tracks.map { ["attributes": ["name": $0]] }]],
        ]
    }

    /// Builds a header.payload.signature JWT from a JSON payload string.
    private static func makeToken(payload: String) -> String {
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}
