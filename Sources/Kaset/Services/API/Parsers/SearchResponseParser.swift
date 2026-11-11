import Foundation

/// Parser for search responses from YouTube Music API.
enum SearchResponseParser {
    private static let logger = DiagnosticsLogger.api

    /// Validates that the response contains a usable search structure.
    static func isValidSearchResponse(_ data: [String: Any]) -> Bool {
        getSectionListRenderer(from: data) != nil
    }

    /// Parses a search response.
    static func parse(_ data: [String: Any]) -> SearchResponse {
        var songs: [Song] = []
        var albums: [Album] = []
        var artists: [Artist] = []
        var playlists: [Playlist] = []
        // YouTube Music's own order: the top-result card, then each shelf in turn.
        var items: [SearchResultItem] = []
        var topResult: SearchTopResult?

        // Navigate to contents
        guard let contents = data["contents"] as? [String: Any],
              let tabbedSearchResults = contents["tabbedSearchResultsRenderer"] as? [String: Any],
              let tabs = tabbedSearchResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            Self.logger.debug("SearchResponseParser: Failed to parse response structure. Top keys: \(data.keys.sorted())")
            return SearchResponse.empty
        }

        for sectionData in sectionContents {
            // Parse musicCardShelfRenderer (Top Result section)
            if let cardShelfRenderer = sectionData["musicCardShelfRenderer"] as? [String: Any],
               let card = parseCardShelfRenderer(cardShelfRenderer)
            {
                topResult = topResult ?? card
                Self.appendItem(card.item, items: &items, songs: &songs, albums: &albums, artists: &artists, playlists: &playlists)
            }

            // Parse musicShelfRenderer (regular results)
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let item = parseSearchResultItem(itemData) {
                        Self.appendItem(item, items: &items, songs: &songs, albums: &albums, artists: &artists, playlists: &playlists)
                    }
                }
            }

            // Parse itemSectionRenderer (newer search results layout)
            if let itemSectionRenderer = sectionData["itemSectionRenderer"] as? [String: Any],
               let itemContents = itemSectionRenderer["contents"] as? [[String: Any]]
            {
                for itemData in itemContents {
                    if let cardShelfRenderer = itemData["musicCardShelfRenderer"] as? [String: Any],
                       let card = parseCardShelfRenderer(cardShelfRenderer)
                    {
                        topResult = topResult ?? card
                        Self.appendItem(card.item, items: &items, songs: &songs, albums: &albums, artists: &artists, playlists: &playlists)
                    } else if let item = parseSearchResultItem(itemData) {
                        Self.appendItem(item, items: &items, songs: &songs, albums: &albums, artists: &artists, playlists: &playlists)
                    }
                }
            }
        }

        return SearchResponse(
            songs: songs,
            albums: albums,
            artists: artists,
            playlists: playlists,
            podcastShows: [],
            continuationToken: nil,
            orderedItems: items,
            topResult: topResult
        )
    }

    /// Helper to append a search result item to the appropriate array, keeping the API's order.
    private static func appendItem(
        _ item: SearchResultItem,
        items: inout [SearchResultItem],
        songs: inout [Song],
        albums: inout [Album],
        artists: inout [Artist],
        playlists: inout [Playlist]
    ) {
        items.append(item)

        switch item {
        case let .song(song):
            songs.append(song)
        case let .album(album):
            albums.append(album)
        case let .artist(artist):
            artists.append(artist)
        case let .playlist(playlist):
            playlists.append(playlist)
        case .podcastShow:
            // Podcast shows not parsed in general search
            break
        }
    }

    /// Parses a filtered songs-only search response.
    /// Filtered searches have a simpler structure without tabs.
    static func parseSongsOnly(_ data: [String: Any]) -> [Song] {
        var songs: [Song] = []

        // Filtered search has a simpler structure - no tabs
        guard let contents = data["contents"] as? [String: Any],
              let sectionListRenderer = contents["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            // Try tabbed structure as fallback
            let response = self.parse(data)
            return response.songs
        }

        for sectionData in sectionContents {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let item = parseSearchResultItem(itemData),
                       case let .song(song) = item
                    {
                        songs.append(song)
                    }
                }
            }

            if let itemSectionRenderer = sectionData["itemSectionRenderer"] as? [String: Any],
               let itemContents = itemSectionRenderer["contents"] as? [[String: Any]]
            {
                for itemData in itemContents {
                    if let item = parseSearchResultItem(itemData),
                       case let .song(song) = item
                    {
                        songs.append(song)
                    }
                }
            }
        }

        return songs
    }

    // MARK: - Item Parsing

    /// Parses a musicCardShelfRenderer (Top Result section): the card's item, its subtitle line and
    /// the rows YouTube Music lists beside it.
    private static func parseCardShelfRenderer(_ data: [String: Any]) -> SearchTopResult? {
        guard let item = self.parseCardItem(data) else { return nil }

        var subtitle: String?
        if let subtitleData = data["subtitle"] as? [String: Any],
           let subtitleRuns = subtitleData["runs"] as? [[String: Any]]
        {
            let line = subtitleRuns.compactMap { $0["text"] as? String }.joined()
            subtitle = line.isEmpty ? nil : line
        }

        let relatedItems = (data["contents"] as? [[String: Any]] ?? [])
            .compactMap { self.parseSearchResultItem($0) }

        return SearchTopResult(item: item, subtitle: subtitle, relatedItems: relatedItems)
    }

    /// The card's own item, taken from the navigation endpoint of its title run.
    private static func parseCardItem(_ data: [String: Any]) -> SearchResultItem? {
        // Extract title and navigation from the title runs
        guard let titleData = data["title"] as? [String: Any],
              let runs = titleData["runs"] as? [[String: Any]],
              let firstRun = runs.first,
              let title = firstRun["text"] as? String
        else {
            return nil
        }

        // Extract thumbnail
        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

        // The card's own subtitle: its kind and numbers ("Artist • 32M monthly audience").
        var subtitle: String?
        if let subtitleData = data["subtitle"] as? [String: Any],
           let subtitleRuns = subtitleData["runs"] as? [[String: Any]]
        {
            subtitle = subtitleRuns.compactMap { $0["text"] as? String }.joined()
        }

        if let navigationEndpoint = firstRun["navigationEndpoint"] as? [String: Any] {
            if let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
               let browseId = browseEndpoint["browseId"] as? String
            {
                let pageType = ParsingHelpers.extractPageType(from: browseEndpoint)
                return self.createItemFromBrowseEndpoint(
                    browseId: browseId,
                    pageType: pageType,
                    title: title,
                    thumbnailURL: thumbnailURL,
                    subtitle: subtitle
                )
            }

            if let watchEndpoint = navigationEndpoint["watchEndpoint"] as? [String: Any],
               let videoId = watchEndpoint["videoId"] as? String
            {
                // The card is often a track's official music video, and its type is what tells
                // the all-results ranking to put the album version in its place. Its byline is the only
                // place the card names the artist ("Song • Oasis • 1.7B plays").
                let song = Song(
                    id: videoId,
                    title: title,
                    artists: ParsingHelpers.extractArtists(from: data),
                    album: nil,
                    duration: nil,
                    thumbnailURL: thumbnailURL,
                    videoId: videoId,
                    musicVideoType: ParsingHelpers.extractMusicVideoType(from: navigationEndpoint)
                )
                return .song(song)
            }
        }

        if let thumbnailOverlay = data["thumbnailOverlay"] as? [String: Any],
           let overlayRenderer = thumbnailOverlay["musicItemThumbnailOverlayRenderer"] as? [String: Any],
           let content = overlayRenderer["content"] as? [String: Any],
           let playButton = content["musicPlayButtonRenderer"] as? [String: Any],            let endpoint = playButton["playNavigationEndpoint"] as? [String: Any],
           let watchEndpoint = endpoint["watchEndpoint"] as? [String: Any],
           let videoId = watchEndpoint["videoId"] as? String
        {
            let song = Song(
                id: videoId,
                title: title,
                artists: ParsingHelpers.extractArtists(from: data),
                album: nil,
                duration: nil,
                thumbnailURL: thumbnailURL,
                videoId: videoId,
                musicVideoType: ParsingHelpers.extractMusicVideoType(from: endpoint)
            )
            return .song(song)
        }

        return nil
    }

    private static func parseSearchResultItem(_ data: [String: Any]) -> SearchResultItem? {
        guard let responsiveRenderer = data["musicResponsiveListItemRenderer"] as? [String: Any] else {
            return nil
        }

        // Try to get videoId for songs
        if let videoId = ParsingHelpers.extractVideoId(from: responsiveRenderer) {
            return self.parseSongFromResponsiveRenderer(responsiveRenderer, videoId: videoId)
        }

        // Check navigation endpoint for other types
        if let navigationEndpoint = responsiveRenderer["navigationEndpoint"] as? [String: Any],
           let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
           let browseId = browseEndpoint["browseId"] as? String
        {
            let thumbnails = ParsingHelpers.extractThumbnails(from: responsiveRenderer)
            let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
            let title = ParsingHelpers.extractTitleFromFlexColumns(responsiveRenderer) ?? "Unknown"
            let subtitle = ParsingHelpers.extractSubtitleFromFlexColumns(responsiveRenderer)

            let pageType = ParsingHelpers.extractPageType(from: browseEndpoint)
            return self.createItemFromBrowseEndpoint(
                browseId: browseId,
                pageType: pageType,
                title: title,
                thumbnailURL: thumbnailURL,
                subtitle: subtitle
            )
        }

        return nil
    }

    // MARK: - Helpers

    private static func createItemFromBrowseEndpoint(
        browseId: String,
        pageType: String?,
        title: String,
        thumbnailURL: URL?,
        subtitle: String?
    ) -> SearchResultItem? {
        if pageType == "MUSIC_PAGE_TYPE_ALBUM" || browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
            let album = Album(
                id: browseId,
                title: title,
                artists: nil,
                thumbnailURL: thumbnailURL,
                year: nil,
                trackCount: nil
            )
            return .album(album)
        }

        if ParsingHelpers.isArtistPageType(pageType) || Artist.isNavigableId(browseId) {
            let artist = Artist(id: browseId, name: title, thumbnailURL: thumbnailURL)
            return .artist(artist)
        }

        if pageType == "MUSIC_PAGE_TYPE_PLAYLIST" || browseId.hasPrefix("VL") || browseId.hasPrefix("PL") {
            let playlist = Playlist(
                id: browseId,
                title: title,
                description: nil,
                thumbnailURL: thumbnailURL,
                trackCount: nil,
                author: subtitle
            )
            return .playlist(playlist)
        }

        return nil
    }

    private static func parseSongFromResponsiveRenderer(
        _ data: [String: Any],
        videoId: String
    ) -> SearchResultItem? {
        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let title = ParsingHelpers.extractTitleFromFlexColumns(data) ?? "Unknown"
        let bylineArtists = ParsingHelpers.extractArtistsFromFlexColumns(data)
        // Some rows leave the artist out of the byline ("Song • 4:39") and keep it only in the play
        // button's label; the row would otherwise show a track with no artist.
        let artists = bylineArtists.isEmpty
            ? ParsingHelpers.extractArtistsFromPlayButtonLabel(data, title: title)
            : bylineArtists
        let album = ParsingHelpers.extractAlbumFromFlexColumns(data)

        let song = Song(
            id: videoId,
            title: title,
            artists: artists,
            album: album,
            duration: ParsingHelpers.extractDurationFromFlexColumns(data),
            thumbnailURL: thumbnailURL,
            videoId: videoId,
            musicVideoType: ParsingHelpers.extractMusicVideoTypeFromFlexColumns(data)
        )
        return .song(song)
    }

    // MARK: - Filtered Search Parsing

    /// Extracts the continuation token from a filtered search response.
    private static func extractContinuationToken(from sectionListRenderer: [String: Any]) -> String? {
        // Check for continuations array
        if let continuations = sectionListRenderer["continuations"] as? [[String: Any]],
           let firstContinuation = continuations.first,
           let nextContinuationData = firstContinuation["nextContinuationData"] as? [String: Any],
           let token = nextContinuationData["continuation"] as? String
        {
            return token
        }
        return nil
    }

    /// Helper to get sectionListRenderer from filtered search response.
    private static func getSectionListRenderer(from data: [String: Any]) -> [String: Any]? {
        // Try filtered search structure first (no tabs)
        if let contents = data["contents"] as? [String: Any],
           let sectionListRenderer = contents["sectionListRenderer"] as? [String: Any]
        {
            return sectionListRenderer
        }

        // Try tabbed structure as fallback
        if let contents = data["contents"] as? [String: Any],
           let tabbedSearchResults = contents["tabbedSearchResultsRenderer"] as? [String: Any],
           let tabs = tabbedSearchResults["tabs"] as? [[String: Any]],
           let firstTab = tabs.first,
           let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
           let tabContent = tabRenderer["content"] as? [String: Any],
           let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any]
        {
            return sectionListRenderer
        }

        return nil
    }

    /// Parses albums from a filtered search response with continuation token.
    static func parseAlbumsOnly(_ data: [String: Any]) -> ([Album], String?) {
        var albums: [Album] = []

        guard let sectionListRenderer = getSectionListRenderer(from: data),
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return ([], nil)
        }

        for sectionData in sectionContents {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let item = parseSearchResultItem(itemData),
                       case let .album(album) = item
                    {
                        albums.append(album)
                    }
                }
            }

            if let itemSectionRenderer = sectionData["itemSectionRenderer"] as? [String: Any],
               let itemContents = itemSectionRenderer["contents"] as? [[String: Any]]
            {
                for itemData in itemContents {
                    if let item = parseSearchResultItem(itemData),
                       case let .album(album) = item
                    {
                        albums.append(album)
                    }
                }
            }
        }

        let token = Self.extractContinuationToken(from: sectionListRenderer)
        return (albums, token)
    }

    /// Parses artists from a filtered search response with continuation token.
    static func parseArtistsOnly(_ data: [String: Any]) -> ([Artist], String?) {
        var artists: [Artist] = []

        guard let sectionListRenderer = getSectionListRenderer(from: data),
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return ([], nil)
        }

        for sectionData in sectionContents {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let item = parseSearchResultItem(itemData),
                       case let .artist(artist) = item
                    {
                        artists.append(artist)
                    }
                }
            }

            if let itemSectionRenderer = sectionData["itemSectionRenderer"] as? [String: Any],
               let itemContents = itemSectionRenderer["contents"] as? [[String: Any]]
            {
                for itemData in itemContents {
                    if let item = parseSearchResultItem(itemData),
                       case let .artist(artist) = item
                    {
                        artists.append(artist)
                    }
                }
            }
        }

        let token = Self.extractContinuationToken(from: sectionListRenderer)
        return (artists, token)
    }

    /// Parses playlists from a filtered search response with continuation token.
    static func parsePlaylistsOnly(_ data: [String: Any]) -> ([Playlist], String?) {
        var playlists: [Playlist] = []

        guard let sectionListRenderer = getSectionListRenderer(from: data),
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return ([], nil)
        }

        for sectionData in sectionContents {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let item = parseSearchResultItem(itemData),
                       case let .playlist(playlist) = item
                    {
                        playlists.append(playlist)
                    }
                }
            }

            if let itemSectionRenderer = sectionData["itemSectionRenderer"] as? [String: Any],
               let itemContents = itemSectionRenderer["contents"] as? [[String: Any]]
            {
                for itemData in itemContents {
                    if let item = parseSearchResultItem(itemData),
                       case let .playlist(playlist) = item
                    {
                        playlists.append(playlist)
                    }
                }
            }
        }

        let token = Self.extractContinuationToken(from: sectionListRenderer)
        return (playlists, token)
    }

    /// Parses podcasts from a filtered search response with continuation token.
    static func parsePodcastsOnly(_ data: [String: Any]) -> ([PodcastShow], String?) {
        var podcasts: [PodcastShow] = []

        guard let sectionListRenderer = getSectionListRenderer(from: data),
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return ([], nil)
        }

        for sectionData in sectionContents {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let show = Self.parsePodcastShowFromSearchResult(itemData) {
                        podcasts.append(show)
                    }
                }
            }

            if let itemSectionRenderer = sectionData["itemSectionRenderer"] as? [String: Any],
               let itemContents = itemSectionRenderer["contents"] as? [[String: Any]]
            {
                for itemData in itemContents {
                    if let show = Self.parsePodcastShowFromSearchResult(itemData) {
                        podcasts.append(show)
                    }
                }
            }
        }

        let token = Self.extractContinuationToken(from: sectionListRenderer)
        return (podcasts, token)
    }

    /// Parses a podcast show from a search result item.
    private static func parsePodcastShowFromSearchResult(_ data: [String: Any]) -> PodcastShow? {
        guard let responsiveRenderer = data["musicResponsiveListItemRenderer"] as? [String: Any] else {
            return nil
        }

        // Check navigation endpoint for browse ID
        guard let navigationEndpoint = responsiveRenderer["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String,
              browseId.hasPrefix("MPSPP")
        else {
            return nil
        }

        let thumbnails = ParsingHelpers.extractThumbnails(from: responsiveRenderer)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let title = ParsingHelpers.extractTitleFromFlexColumns(responsiveRenderer) ?? "Unknown Podcast"
        let author = ParsingHelpers.extractSubtitleFromFlexColumns(responsiveRenderer)

        return PodcastShow(
            id: browseId,
            title: title,
            author: author,
            description: nil,
            thumbnailURL: thumbnailURL,
            episodeCount: nil
        )
    }

    /// Parses songs from a filtered search response with continuation token.
    static func parseSongsWithContinuation(_ data: [String: Any]) -> ([Song], String?) {
        var songs: [Song] = []

        guard let sectionListRenderer = getSectionListRenderer(from: data),
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            return ([], nil)
        }

        for sectionData in sectionContents {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let item = parseSearchResultItem(itemData),
                       case let .song(song) = item
                    {
                        songs.append(song)
                    }
                }
            }

            if let itemSectionRenderer = sectionData["itemSectionRenderer"] as? [String: Any],
               let itemContents = itemSectionRenderer["contents"] as? [[String: Any]]
            {
                for itemData in itemContents {
                    if let item = parseSearchResultItem(itemData),
                       case let .song(song) = item
                    {
                        songs.append(song)
                    }
                }
            }
        }

        let token = Self.extractContinuationToken(from: sectionListRenderer)
        return (songs, token)
    }

    /// Parses a search continuation response.
    /// Returns a SearchResponse with all item types and optional continuation token.
    static func parseContinuation(_ data: [String: Any]) -> SearchResponse {
        var songs: [Song] = []
        var albums: [Album] = []
        var artists: [Artist] = []
        var playlists: [Playlist] = []
        var podcastShows: [PodcastShow] = []
        var items: [SearchResultItem] = []
        var continuationToken: String?

        // Continuation responses have a different structure
        if let continuationContents = data["continuationContents"] as? [String: Any],
           let musicShelfContinuation = continuationContents["musicShelfContinuation"] as? [String: Any]
        {
            // Parse items
            if let contents = musicShelfContinuation["contents"] as? [[String: Any]] {
                for itemData in contents {
                    // Try to parse as podcast show first (for podcast search continuation)
                    if let show = Self.parsePodcastShowFromSearchResult(itemData) {
                        podcastShows.append(show)
                        items.append(.podcastShow(show))
                    } else if let item = parseSearchResultItem(itemData) {
                        Self.appendItem(item, items: &items, songs: &songs, albums: &albums, artists: &artists, playlists: &playlists)
                    }
                }
            }

            // Extract next continuation token
            if let continuations = musicShelfContinuation["continuations"] as? [[String: Any]],
               let firstContinuation = continuations.first,
               let nextContinuationData = firstContinuation["nextContinuationData"] as? [String: Any],
               let token = nextContinuationData["continuation"] as? String
            {
                continuationToken = token
            }
        }

        return SearchResponse(
            songs: songs,
            albums: albums,
            artists: artists,
            playlists: playlists,
            podcastShows: podcastShows,
            continuationToken: continuationToken,
            orderedItems: items
        )
    }
}
