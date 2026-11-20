import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service))
struct TrackAlbumResolverTests {
    // MARK: - When an album is corrected

    @Test("a single named after the track is corrected, a real album is not")
    func needsResolution() {
        #expect(TrackAlbumResolver.needsResolution(albumTitle: "Flowers", trackTitle: "Flowers"))
        #expect(TrackAlbumResolver.needsResolution(albumTitle: "Flowers - Single", trackTitle: "Flowers"))
        #expect(TrackAlbumResolver.needsResolution(albumTitle: "Good Days - EP", trackTitle: "Good Days"))
        #expect(TrackAlbumResolver.needsResolution(albumTitle: "Endless Summer Vacation", trackTitle: "Flowers") == false)
        #expect(TrackAlbumResolver.needsResolution(albumTitle: "", trackTitle: "Flowers") == false)
        #expect(TrackAlbumResolver.needsResolution(albumTitle: "Flowers", trackTitle: "   ") == false)
    }

    @Test("the search asks for the track on the artist's releases")
    func searchQuery() {
        #expect(TrackAlbumResolver.searchQuery(trackTitle: "Flowers", artist: "Miley Cyrus") == "Miley Cyrus Flowers")
        #expect(TrackAlbumResolver.searchQuery(trackTitle: " Flowers ", artist: " ") == "Flowers")
    }

    @Test("titles match ignoring case, accents and spacing")
    func titlesMatch() {
        #expect(TrackAlbumResolver.titlesMatch("Flowers", "flowers"))
        #expect(TrackAlbumResolver.titlesMatch("ROSALÍA", "Rosalia"))
        #expect(TrackAlbumResolver.titlesMatch("  Flowers ", "Flowers"))
        #expect(TrackAlbumResolver.titlesMatch("Flowers", "Jaded") == false)
        #expect(TrackAlbumResolver.titlesMatch("", "Flowers") == false)
    }

    // MARK: - Candidates

    /// A filtered search row names the album's page and artist in its subtitle but parses no artists,
    /// so an uncredited row is a candidate; another artist's album is not.
    @Test("candidates are navigable album pages that are not credited to another artist")
    func candidates() {
        let albums = [
            Album(id: "MPREb_a", title: "Endless Summer Vacation", artists: nil, thumbnailURL: nil, year: nil, trackCount: nil),
            Album(id: "MPREb_b", title: "Flowers", artists: [Artist(id: "UCpiano", name: "Sing2Piano")], thumbnailURL: nil, year: "2023", trackCount: 12),
            Album(id: "not-navigable", title: "Something", artists: nil, thumbnailURL: nil, year: nil, trackCount: nil),
        ]
        #expect(TrackAlbumResolver.candidates(from: albums, artist: "Miley Cyrus").map(\.id) == ["MPREb_a"])
    }

    /// The album of a collaboration is credited to the lead artist alone.
    @Test("a collaboration matches the album credited to one of its artists")
    func collaborationCandidates() {
        let albums = [
            Album(id: "MPREb_x", title: "Honestly, Nevermind", artists: [Artist(id: "UCdrake", name: "Drake")], thumbnailURL: nil, year: "2022", trackCount: 14),
        ]
        #expect(TrackAlbumResolver.candidates(from: albums, artist: "Drake, 21 Savage").count == 1)
    }

    // MARK: - Resolution

    @Test("the album whose page lists the song wins over the single and an album without it")
    func resolvesTheAlbumThatHoldsTheSong() async {
        let single = Self.album(id: "MPREb_single", title: "Flowers")
        let other = Self.album(id: "MPREb_other", title: "Plastic Hearts")
        let album = Self.album(id: "MPREb_album", title: "Endless Summer Vacation")

        let resolved = await TrackAlbumResolver.resolve(
            trackTitle: "Flowers",
            artist: "Miley Cyrus",
            searchAlbums: { _ in [single, other, album] },
            albumPage: { albumId in
                switch albumId {
                case "MPREb_single": Self.page(id: albumId, title: "Flowers", artist: "Miley Cyrus", tracks: ["Flowers"])
                case "MPREb_other": Self.page(id: albumId, title: "Plastic Hearts", artist: "Miley Cyrus", tracks: ["Wrecking Ball", "Angels Like You"])
                default: Self.page(id: albumId, title: "Endless Summer Vacation", artist: "Miley Cyrus", tracks: ["Flowers", "Jaded", "Rose Colored Lenses"])
                }
            }
        )

        #expect(resolved?.id == "MPREb_album")
        #expect(resolved?.title == "Endless Summer Vacation")
        #expect(resolved?.trackCount == 3)
    }

    /// Another artist's release of the same song is not the song's album.
    @Test("an album of the song by another artist is skipped")
    func skipsACoversAlbum() async {
        let cover = Self.album(id: "MPREb_cover", title: "Flowers (Piano Version)")
        let album = Self.album(id: "MPREb_album", title: "Endless Summer Vacation")

        let resolved = await TrackAlbumResolver.resolve(
            trackTitle: "Flowers",
            artist: "Miley Cyrus",
            searchAlbums: { _ in [cover, album] },
            albumPage: { albumId in
                switch albumId {
                case "MPREb_cover": Self.page(id: albumId, title: "Flowers (Piano Version)", artist: "Sing2Piano", tracks: ["Flowers", "Jaded"])
                default: Self.page(id: albumId, title: "Endless Summer Vacation", artist: "Miley Cyrus", tracks: ["Flowers", "Jaded"])
                }
            }
        )

        #expect(resolved?.id == "MPREb_album")
    }

    @Test("no album is invented when no page lists the song")
    func resolvesNothingWhenUnproven() async {
        let album = Self.album(id: "MPREb_a", title: "Plastic Hearts")
        let resolved = await TrackAlbumResolver.resolve(
            trackTitle: "Flowers",
            artist: "Miley Cyrus",
            searchAlbums: { _ in [album] },
            albumPage: { Self.page(id: $0, title: "Plastic Hearts", artist: "Miley Cyrus", tracks: ["Wrecking Ball"]) }
        )
        #expect(resolved == nil)
    }

    @Test("a failed search or a failed album page resolves nothing")
    func failuresResolveNothing() async {
        let failedSearch = await TrackAlbumResolver.resolve(
            trackTitle: "Flowers",
            artist: "Miley Cyrus",
            searchAlbums: { _ in throw YTMusicError.parseError(message: "network") },
            albumPage: { Self.page(id: $0, title: "Flowers", artist: "Miley Cyrus", tracks: ["Flowers", "Jaded"]) }
        )
        #expect(failedSearch == nil)

        let album = Self.album(id: "MPREb_a", title: "Endless Summer Vacation")
        let failedPage = await TrackAlbumResolver.resolve(
            trackTitle: "Flowers",
            artist: "Miley Cyrus",
            searchAlbums: { _ in [album] },
            albumPage: { _ in throw YTMusicError.parseError(message: "network") }
        )
        #expect(failedPage == nil)
    }

    // MARK: - Helpers

    /// A filtered-search album row: it names the page but carries no credits.
    private static func album(id: String, title: String) -> Album {
        Album(id: id, title: title, artists: nil, thumbnailURL: nil, year: nil, trackCount: nil)
    }

    private static func page(id: String, title: String, artist: String, tracks: [String]) -> PlaylistDetail {
        PlaylistDetail(
            playlist: Playlist(
                id: id,
                title: title,
                description: nil,
                thumbnailURL: nil,
                trackCount: tracks.count,
                author: nil
            ),
            tracks: tracks.enumerated().map { index, trackTitle in
                Song(id: "\(id)-\(index)", title: trackTitle, artists: [], videoId: "\(id)-\(index)")
            },
            artists: [Artist(id: "UC\(id)", name: artist)]
        )
    }
}
