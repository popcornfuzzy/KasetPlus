import Foundation

// MARK: - SearchResponse

/// Response from a YouTube Music search query.
struct SearchResponse {
    let songs: [Song]
    let albums: [Album]
    let artists: [Artist]
    let playlists: [Playlist]
    let podcastShows: [PodcastShow]
    /// Continuation token for loading more results (only present for filtered searches).
    let continuationToken: String?

    /// The results in the order YouTube Music returned them: the top-result card first, then each
    /// shelf in turn. That order is the ranking; responses built in code fall back to grouping by
    /// kind.
    let orderedItems: [SearchResultItem]

    /// YouTube Music's top-result card, when it returned one. The card is also the first of
    /// `orderedItems`; the view draws it as a hero instead of a row.
    let topResult: SearchTopResult?

    /// All results as a flat array, in YouTube Music's own order.
    var allItems: [SearchResultItem] {
        self.orderedItems
    }

    /// Whether the search returned any results.
    var isEmpty: Bool {
        self.songs.isEmpty && self.albums.isEmpty && self.artists.isEmpty && self.playlists.isEmpty && self.podcastShows.isEmpty
    }

    /// Whether more results are available to load.
    var hasMore: Bool {
        self.continuationToken != nil
    }

    static let empty = SearchResponse(songs: [], albums: [], artists: [], playlists: [], podcastShows: [], continuationToken: nil)

    /// Creates a SearchResponse without continuation token (backward compatibility).
    init(
        songs: [Song],
        albums: [Album],
        artists: [Artist],
        playlists: [Playlist],
        orderedItems: [SearchResultItem]? = nil
    ) {
        self.init(
            songs: songs,
            albums: albums,
            artists: artists,
            playlists: playlists,
            podcastShows: [],
            continuationToken: nil,
            orderedItems: orderedItems
        )
    }

    /// Creates a SearchResponse with optional continuation token (backward compatibility).
    init(
        songs: [Song],
        albums: [Album],
        artists: [Artist],
        playlists: [Playlist],
        continuationToken: String?,
        orderedItems: [SearchResultItem]? = nil
    ) {
        self.init(
            songs: songs,
            albums: albums,
            artists: artists,
            playlists: playlists,
            podcastShows: [],
            continuationToken: continuationToken,
            orderedItems: orderedItems
        )
    }

    /// Creates a SearchResponse with podcast shows and optional continuation token.
    init(
        songs: [Song],
        albums: [Album],
        artists: [Artist],
        playlists: [Playlist],
        podcastShows: [PodcastShow],
        continuationToken: String?,
        orderedItems: [SearchResultItem]? = nil,
        topResult: SearchTopResult? = nil
    ) {
        self.songs = songs
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
        self.podcastShows = podcastShows
        self.continuationToken = continuationToken
        self.orderedItems = orderedItems ?? Self.groupedItems(
            songs: songs,
            albums: albums,
            artists: artists,
            playlists: playlists,
            podcastShows: podcastShows
        )
        self.topResult = topResult
    }

    /// Fallback order for responses built in code: one kind after another.
    private static func groupedItems(
        songs: [Song],
        albums: [Album],
        artists: [Artist],
        playlists: [Playlist],
        podcastShows: [PodcastShow]
    ) -> [SearchResultItem] {
        songs.map { SearchResultItem.song($0) }
            + albums.map { SearchResultItem.album($0) }
            + artists.map { SearchResultItem.artist($0) }
            + playlists.map { SearchResultItem.playlist($0) }
            + podcastShows.map { SearchResultItem.podcastShow($0) }
    }
}

// MARK: - SearchResultItem

/// A search result item (can be any content type).
enum SearchResultItem: Identifiable {
    case song(Song)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
    case podcastShow(PodcastShow)

    var id: String {
        switch self {
        case let .song(song):
            "song-\(song.id)"
        case let .album(album):
            "album-\(album.id)"
        case let .artist(artist):
            "artist-\(artist.id)"
        case let .playlist(playlist):
            "playlist-\(playlist.id)"
        case let .podcastShow(show):
            "podcast-\(show.id)"
        }
    }

    var title: String {
        switch self {
        case let .song(song):
            song.title
        case let .album(album):
            album.title
        case let .artist(artist):
            artist.name
        case let .playlist(playlist):
            playlist.title
        case let .podcastShow(show):
            show.title
        }
    }

    var subtitle: String? {
        switch self {
        case let .song(song):
            let display = song.artistsDisplay
            return display.isEmpty ? nil : display
        case let .album(album):
            let display = album.artistsDisplay
            return display.isEmpty ? nil : display
        case .artist:
            // No additional subtitle needed - resultType already shows "Artist"
            return nil
        case let .playlist(playlist):
            // Strip "Playlist • " prefix since resultType already shows "Playlist"
            guard let author = playlist.author else { return nil }
            let stripped = author
                .replacingOccurrences(of: "Playlist • ", with: "")
                .trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty ? nil : stripped
        case let .podcastShow(show):
            return show.author
        }
    }

    var thumbnailURL: URL? {
        switch self {
        case let .song(song):
            song.thumbnailURL
        case let .album(album):
            album.thumbnailURL
        case let .artist(artist):
            artist.thumbnailURL
        case let .playlist(playlist):
            playlist.thumbnailURL
        case let .podcastShow(show):
            show.thumbnailURL
        }
    }

    var resultType: String {
        switch self {
        case .song:
            "Song"
        case .album:
            "Album"
        case .artist:
            "Artist"
        case .playlist:
            "Playlist"
        case .podcastShow:
            "Podcast"
        }
    }

    /// SF Symbol for the item's kind, used where its artwork is missing.
    var systemImage: String {
        switch self {
        case .song:
            "music.note"
        case .album:
            "square.stack"
        case .artist:
            "person"
        case .playlist:
            "music.note.list"
        case .podcastShow:
            "mic.fill"
        }
    }

    /// Returns the video ID if this item is directly playable.
    var videoId: String? {
        switch self {
        case let .song(song):
            song.videoId
        default:
            nil
        }
    }
}
