import Foundation
import Testing
@testable import Kaset

/// Tests for `SearchResultRanker`.
@Suite(.tags(.model))
@MainActor
struct SearchResultRankerTests {
    private func makeSong(
        videoId: String,
        title: String,
        artist: String? = nil,
        musicVideoType: MusicVideoType? = nil
    ) -> Song {
        Song(
            id: videoId,
            title: title,
            artists: artist.map { [Artist(id: "UC-\($0)", name: $0)] } ?? [],
            album: nil,
            duration: 214,
            thumbnailURL: nil,
            videoId: videoId,
            musicVideoType: musicVideoType
        )
    }

    private func makeAlbum(id: String = "MPRE1") -> Album {
        Album(id: id, title: "Album", artists: nil, thumbnailURL: nil, year: nil, trackCount: nil)
    }

    private func makePlaylist(id: String = "PL1") -> Playlist {
        Playlist(id: id, title: "Playlist", description: nil, thumbnailURL: nil, trackCount: nil, author: nil)
    }

    // MARK: - Song / video pairs

    @Test("The album version takes the top-result music video's row")
    func albumVersionTakesVideoRow() {
        // The "Top result" card carries no artist names; the shelf row below it names them.
        let video = self.makeSong(videoId: "video-id", title: "Wonderwall", musicVideoType: .omv)
        let audio = self.makeSong(videoId: "audio-id", title: "Wonderwall", artist: "Oasis", musicVideoType: .atv)

        #expect(SearchResultRanker.audioPreferred([video, audio]).map(\.videoId) == ["audio-id"])
    }

    @Test("A top-result card without artists is superseded by the same-titled song")
    func cardWithoutArtistsSuperseded() {
        // A card that reports no video type and names no artist: the shelf row identifies it.
        let card = self.makeSong(videoId: "card-id", title: "Wonderwall")
        let audio = self.makeSong(videoId: "audio-id", title: "Wonderwall", artist: "Oasis", musicVideoType: .atv)

        #expect(SearchResultRanker.audioPreferred([card, audio]).map(\.videoId) == ["audio-id"])
    }

    @Test("A music video below the album version is dropped")
    func videoBelowAlbumVersionDropped() {
        let audio = self.makeSong(videoId: "audio-id", title: "Wonderwall", artist: "Oasis", musicVideoType: .atv)
        let video = self.makeSong(
            videoId: "video-id", title: "Wonderwall (Official Video)", artist: "Oasis", musicVideoType: .omv
        )

        #expect(SearchResultRanker.audioPreferred([audio, video]).map(\.videoId) == ["audio-id"])
    }

    @Test("Different artists with the same title are all kept")
    func differentArtistsSameTitleKept() {
        let oasis = self.makeSong(videoId: "oasis-id", title: "Wonderwall", artist: "Oasis", musicVideoType: .atv)
        let cover = self.makeSong(videoId: "cover-id", title: "Wonderwall", artist: "Boyce Avenue", musicVideoType: .atv)
        let otherVideo = self.makeSong(videoId: "video-id", title: "Wonderwall", artist: "OSIS", musicVideoType: .omv)

        #expect(
            SearchResultRanker.audioPreferred([oasis, cover, otherVideo]).map(\.videoId)
                == ["oasis-id", "cover-id", "video-id"]
        )
    }

    @Test("Unrelated songs keep their order")
    func unrelatedSongsKeepOrder() {
        let first = self.makeSong(videoId: "first-id", title: "Wonderwall", artist: "Oasis", musicVideoType: .atv)
        let second = self.makeSong(videoId: "second-id", title: "Live Forever", artist: "Oasis", musicVideoType: .atv)
        let third = self.makeSong(videoId: "third-id", title: "Supersonic", artist: "Oasis", musicVideoType: .atv)

        #expect(
            SearchResultRanker.audioPreferred([first, second, third]).map(\.videoId)
                == ["first-id", "second-id", "third-id"]
        )
    }

    // MARK: - Order

    @Test("The list keeps YouTube Music's order")
    func keepsYouTubeMusicOrder() {
        let song = self.makeSong(videoId: "song-id", title: "Live Forever", artist: "Oasis", musicVideoType: .atv)
        let album = self.makeAlbum()
        let artist = Artist(id: "UC-oasis", name: "Oasis")

        let response = SearchResponse(
            songs: [song],
            albums: [album],
            artists: [artist],
            playlists: [],
            podcastShows: [],
            continuationToken: nil,
            orderedItems: [.artist(artist), .playlist(self.makePlaylist()), .song(song), .album(album)]
        )

        #expect(
            SearchResultRanker.ranked(response).map(\.id)
                == ["artist-UC-oasis", "playlist-PL1", "song-song-id", "album-MPRE1"]
        )
    }

    @Test("The top-result video is replaced in place, not moved")
    func topResultVideoReplacedInPlace() {
        let card = self.makeSong(videoId: "card-id", title: "Wonderwall", musicVideoType: .omv)
        let audio = self.makeSong(videoId: "audio-id", title: "Wonderwall", artist: "Oasis", musicVideoType: .atv)
        let artist = Artist(id: "UC-oasis", name: "Oasis")

        let response = SearchResponse(
            songs: [card, audio],
            albums: [],
            artists: [artist],
            playlists: [],
            podcastShows: [],
            continuationToken: nil,
            orderedItems: [.song(card), .song(audio), .artist(artist)]
        )

        #expect(SearchResultRanker.ranked(response).map(\.id) == ["song-audio-id", "artist-UC-oasis"])
    }

    @Test("Non-song rows between songs keep their place")
    func nonSongRowsKeepPlace() {
        let first = self.makeSong(videoId: "first-id", title: "Wonderwall", artist: "Oasis", musicVideoType: .atv)
        let second = self.makeSong(videoId: "second-id", title: "Live Forever", artist: "Oasis", musicVideoType: .atv)
        let artist = Artist(id: "UC-oasis", name: "Oasis")

        let response = SearchResponse(
            songs: [first, second],
            albums: [],
            artists: [artist],
            playlists: [],
            podcastShows: [],
            continuationToken: nil,
            orderedItems: [.song(first), .artist(artist), .song(second)]
        )

        #expect(
            SearchResultRanker.ranked(response).map(\.id)
                == ["song-first-id", "artist-UC-oasis", "song-second-id"]
        )
    }

    // MARK: - Top result card

    @Test("The hero card's row is left out of the list")
    func heroRowLeavesTheList() {
        let hero = self.makeSong(videoId: "hero-id", title: "Wonderwall", artist: "Oasis", musicVideoType: .atv)
        let next = self.makeSong(videoId: "next-id", title: "Live Forever", artist: "Oasis", musicVideoType: .atv)

        let response = SearchResponse(
            songs: [hero, next],
            albums: [],
            artists: [],
            playlists: [],
            podcastShows: [],
            continuationToken: nil,
            orderedItems: [.song(hero), .song(next)],
            topResult: SearchTopResult(item: .song(hero), subtitle: "Video • Oasis", relatedItems: [])
        )

        #expect(SearchResultRanker.ranked(response).map(\.id) == ["song-next-id"])
    }

    @Test("The hero shows the album version of the card's video")
    func heroShowsAlbumVersion() {
        let video = self.makeSong(videoId: "video-id", title: "Wonderwall", musicVideoType: .omv)
        let audio = self.makeSong(videoId: "audio-id", title: "Wonderwall", artist: "Oasis", musicVideoType: .atv)

        let response = SearchResponse(
            songs: [video, audio],
            albums: [],
            artists: [],
            playlists: [],
            podcastShows: [],
            continuationToken: nil,
            orderedItems: [.song(video), .song(audio)],
            topResult: SearchTopResult(item: .song(video), subtitle: "Video • Oasis", relatedItems: [])
        )

        #expect(SearchResultRanker.topResult(response)?.item.id == "song-audio-id")
        #expect(SearchResultRanker.ranked(response).isEmpty)
    }

    @Test("An artist card keeps its own line and related rows")
    func artistCardKeepsLineAndRows() {
        let artist = Artist(id: "UC-oasis", name: "Oasis")
        let song = self.makeSong(videoId: "song-id", title: "Wonderwall", artist: "Oasis", musicVideoType: .atv)

        let response = SearchResponse(
            songs: [song],
            albums: [],
            artists: [artist],
            playlists: [],
            podcastShows: [],
            continuationToken: nil,
            orderedItems: [.artist(artist), .song(song)],
            topResult: SearchTopResult(
                item: .artist(artist),
                subtitle: "Artist • 32M monthly audience",
                relatedItems: [.song(song)]
            )
        )

        let top = SearchResultRanker.topResult(response)
        #expect(top?.item.id == "artist-UC-oasis")
        #expect(top?.subtitle == "Artist • 32M monthly audience")
        #expect(top?.relatedItems.map(\.id) == ["song-song-id"])
        #expect(SearchResultRanker.ranked(response).map(\.id) == ["song-song-id"])
    }
}
