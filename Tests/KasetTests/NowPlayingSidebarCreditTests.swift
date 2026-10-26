import Foundation
import Testing

@testable import Kaset

/// What the Now Playing column's title and artist line open.
///
/// The column is the app's right sidebar, so the title and the credited names look exactly as they
/// always did — they only became clickable. A song can credit one artist or several, and either of them
/// can carry an ID that is not a page (an inline reference with a generated UUID), which is the case the
/// credit has to drop back to plain text for. Podcast episodes are neither.
struct NowPlayingSidebarCreditTests {
    private static func artist(_ id: String, _ name: String) -> Artist {
        Artist(id: id, name: name)
    }

    private static func song(
        artists: [Artist],
        album: Album? = nil,
        thumbnailURL: URL? = URL(string: "https://example.com/song.jpg")
    ) -> Song {
        Song(
            id: "video-1",
            title: "A Song",
            artists: artists,
            album: album,
            duration: 200,
            thumbnailURL: thumbnailURL,
            videoId: "video-1"
        )
    }

    @Test("The title opens the song's album as a playlist page")
    func albumBecomesAPlaylistPage() {
        let album = Album(
            id: "MPREb_test",
            title: "An Album",
            artists: nil,
            thumbnailURL: nil,
            year: "2026",
            trackCount: 12
        )
        let credits = NowPlayingSidebarCredits(
            song: Self.song(artists: [Self.artist("UCone", "One")], album: album),
            isPodcast: false
        )

        #expect(credits.album?.id == "MPREb_test")
        #expect(credits.album?.title == "An Album")
        // The album carries no artwork of its own here, so the page opens on the song's.
        #expect(credits.album?.thumbnailURL == URL(string: "https://example.com/song.jpg"))
        #expect(credits.album?.author == "One")
        #expect(credits.artists.count == 1)
        #expect(credits.artists.first?.opensPage == true)
    }

    @Test("A song crediting three artists credits each of them, in order")
    func everyArtistIsItsOwnCredit() {
        let artists = [
            Self.artist("UCone", "One"),
            Self.artist("UCtwo", "Two"),
            Self.artist("MPLAUCthree", "Three"),
        ]
        let credits = NowPlayingSidebarCredits(song: Self.song(artists: artists), isPodcast: false)

        #expect(credits.artists.map(\.artist.name) == ["One", "Two", "Three"])
        #expect(credits.artists.map(\.artist.id) == ["UCone", "UCtwo", "MPLAUCthree"])

        let everyNameOpensAPage = credits.artists.allSatisfy(\.opensPage)
        #expect(everyNameOpensAPage, "each name is a page that can be opened")
        #expect(Set(credits.artists.map(\.id)).count == 3, "each name is its own view identity")
    }

    @Test("An artist with no channel ID stays plain text")
    func nonNavigableArtistStaysText() {
        let artists = [
            Self.artist("UCone", "One"),
            Self.artist("7B2C4C1E-0000-0000-0000-000000000000", "Inline Reference"),
        ]
        let credits = NowPlayingSidebarCredits(song: Self.song(artists: artists), isPodcast: false)

        #expect(credits.artists.map(\.opensPage) == [true, false])
    }

    @Test("An album with no browse ID is not opened, and the artists still are")
    func nonNavigableAlbumLeavesTheTitlePlain() {
        let album = Album(
            id: "7B2C4C1E-0000-0000-0000-000000000000",
            title: "Inline Album",
            artists: nil,
            thumbnailURL: nil,
            year: nil,
            trackCount: nil
        )
        let credits = NowPlayingSidebarCredits(
            song: Self.song(artists: [Self.artist("UCone", "One")], album: album),
            isPodcast: false
        )

        #expect(credits.album == nil)
        #expect(credits.artists.first?.opensPage == true)
    }

    @Test("A podcast episode opens neither, and still credits its names")
    func podcastCreditsAreNotPages() {
        let album = Album(
            id: "MPREb_show",
            title: "A Show",
            artists: nil,
            thumbnailURL: nil,
            year: nil,
            trackCount: nil
        )
        let credits = NowPlayingSidebarCredits(
            song: Self.song(artists: [Self.artist("UCone", "One")], album: album),
            isPodcast: true
        )

        #expect(credits.album == nil)
        #expect(credits.artists.map(\.artist.name) == ["One"])
        #expect(credits.artists.first?.opensPage == false)
    }

    @Test("With nothing playing there is nothing to open")
    func noTrackHasNoCredits() {
        let credits = NowPlayingSidebarCredits(song: nil, isPodcast: false)

        #expect(credits.album == nil)
        #expect(credits.artists.isEmpty)
        #expect(credits.hasSong == false)
    }
}
