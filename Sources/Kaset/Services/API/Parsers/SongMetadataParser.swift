import Foundation

/// Parses song metadata from YouTube Music API responses.
enum SongMetadataParser {
    private static let logger = DiagnosticsLogger.api

    /// Contains parsed menu data including feedback tokens and library status.
    struct MenuParseResult {
        var feedbackTokens: FeedbackTokens?
        var isInLibrary: Bool
    }

    /// Parses song metadata from the "next" endpoint response.
    /// - Parameters:
    ///   - data: The response from the "next" endpoint
    ///   - videoId: The video ID of the song
    /// - Returns: A fully parsed Song object
    /// - Throws: `YTMusicError.parseError` if the structure cannot be parsed
    static func parse(_ data: [String: Any], videoId: String) throws -> Song {
        let panelVideoRenderer = try extractPanelVideoRenderer(from: data, videoId: videoId)

        let title = self.parseTitle(from: panelVideoRenderer)
        // The byline names the album as well as the artists, and it says which is which: the album's
        // run is a link to a `MUSIC_PAGE_TYPE_ALBUM` page. Parsed as the album it can open, and kept
        // out of the artist line, instead of arriving as an artist the way it used to.
        let album = self.parseAlbum(from: panelVideoRenderer)
        let artists = self.parseArtists(from: panelVideoRenderer, albumTitle: album?.title)
        let thumbnailURL = self.parseThumbnail(from: panelVideoRenderer)
        let duration = self.parseDuration(from: panelVideoRenderer)
        let menuData = self.parseMenuData(from: panelVideoRenderer)
        let likeStatus = self.parseLikeStatus(from: data)
        let musicVideoType = self.parseMusicVideoType(from: panelVideoRenderer)

        var song = Song(
            id: videoId,
            title: title,
            artists: artists,
            album: album,
            duration: duration,
            thumbnailURL: thumbnailURL,
            videoId: videoId,
            musicVideoType: musicVideoType,
            likeStatus: likeStatus,
            isInLibrary: menuData.isInLibrary,
            feedbackTokens: menuData.feedbackTokens
        )

        // Attach the paired variant when the watch queue wraps the track with a counterpart.
        if let counterpartRenderer = Self.counterpartRenderer(from: data),
           let counterpart = PlaylistPanelItemParser.song(fromRenderer: counterpartRenderer)
        {
            song = song.paired(with: counterpart)
        }

        return song
    }

    /// Extracts the counterpart renderer from the first watch-queue item, when present.
    static func counterpartRenderer(from data: [String: Any]) -> [String: Any]? {
        guard let contents = data["contents"] as? [String: Any],
              let watchNextRenderer = contents["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any],
              let tabbedRenderer = watchNextRenderer["tabbedRenderer"] as? [String: Any],
              let watchNextTabbedResults = tabbedRenderer["watchNextTabbedResultsRenderer"] as? [String: Any],
              let tabs = watchNextTabbedResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let musicQueueRenderer = tabContent["musicQueueRenderer"] as? [String: Any],
              let queueContent = musicQueueRenderer["content"] as? [String: Any],
              let playlistPanelRenderer = queueContent["playlistPanelRenderer"] as? [String: Any],
              let playlistContents = playlistPanelRenderer["contents"] as? [[String: Any]],
              let firstItem = playlistContents.first,
              let wrapper = firstItem["playlistPanelVideoWrapperRenderer"] as? [String: Any]
        else {
            return nil
        }

        return PlaylistPanelItemParser.counterpartRenderer(in: wrapper)
    }

    /// Extracts the playlistPanelVideoRenderer from the next endpoint response.
    /// Handles both direct and wrapped renderer structures.
    static func extractPanelVideoRenderer(from data: [String: Any], videoId: String) throws -> [String: Any] {
        guard let contents = data["contents"] as? [String: Any],
              let watchNextRenderer = contents["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any],
              let tabbedRenderer = watchNextRenderer["tabbedRenderer"] as? [String: Any],
              let watchNextTabbedResults = tabbedRenderer["watchNextTabbedResultsRenderer"] as? [String: Any],
              let tabs = watchNextTabbedResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let musicQueueRenderer = tabContent["musicQueueRenderer"] as? [String: Any],
              let queueContent = musicQueueRenderer["content"] as? [String: Any],
              let playlistPanelRenderer = queueContent["playlistPanelRenderer"] as? [String: Any],
              let playlistContents = playlistPanelRenderer["contents"] as? [[String: Any]],
              let firstItem = playlistContents.first
        else {
            throw YTMusicError.parseError(message: "Failed to parse song metadata for \(videoId)")
        }

        // Handle both direct and wrapped renderer structures
        // Direct: firstItem.playlistPanelVideoRenderer
        // Wrapped: firstItem.playlistPanelVideoWrapperRenderer.primaryRenderer.playlistPanelVideoRenderer
        if let direct = firstItem["playlistPanelVideoRenderer"] as? [String: Any] {
            return direct
        } else if let wrapper = firstItem["playlistPanelVideoWrapperRenderer"] as? [String: Any],
                  let primary = wrapper["primaryRenderer"] as? [String: Any],
                  let wrapped = primary["playlistPanelVideoRenderer"] as? [String: Any]
        {
            return wrapped
        }

        throw YTMusicError.parseError(message: "Failed to parse song metadata for \(videoId)")
    }

    /// Parses the song title from the panel video renderer.
    static func parseTitle(from renderer: [String: Any]) -> String {
        if let titleData = renderer["title"] as? [String: Any],
           let runs = titleData["runs"] as? [[String: Any]],
           let firstRun = runs.first,
           let text = firstRun["text"] as? String
        {
            return text
        }
        return "Unknown"
    }

    /// Parses the album the byline names, with the release year beside it.
    ///
    /// A song's byline is "Artist • Album • Year", and YouTube marks the album's run as a link to a
    /// `MUSIC_PAGE_TYPE_ALBUM` page (`MPRE…`/`OLAK…`). That is the record of which album the track is
    /// on — it is not parsed out of the artists, and the title can open it.
    static func parseAlbum(from renderer: [String: Any]) -> Album? {
        guard let bylineData = renderer["longBylineText"] as? [String: Any],
              let runs = bylineData["runs"] as? [[String: Any]]
        else { return nil }

        for run in runs {
            guard let title = (run["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  let browseId = Self.browseId(of: run),
                  browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK")
            else { continue }

            let year = runs
                .compactMap { $0["text"] as? String }
                .first { ParsingHelpers.isStandaloneYear($0) }

            return Album(
                id: browseId,
                title: title,
                artists: nil,
                thumbnailURL: nil,
                year: year,
                trackCount: nil
            )
        }

        return nil
    }

    /// Parses artists from the panel video renderer's longBylineText.
    ///
    /// A byline is not a list of artists: it is "Artist • Album • Year" for a song, and
    /// "Artist • 1.8B views • 19M likes" for a video. Only a run that names an artist's page is an
    /// artist; a link to anything else (the album, a playlist) and a run of metadata are not, and the
    /// album the app already parsed is never one either. A byline written as plain text keeps its names,
    /// which is how an uploaded track with no linked artist still shows who made it.
    static func parseArtists(from renderer: [String: Any], albumTitle: String? = nil) -> [Artist] {
        guard let bylineData = renderer["longBylineText"] as? [String: Any],
              let runs = bylineData["runs"] as? [[String: Any]]
        else { return [] }

        var linked: [Artist] = []
        var plain: [String] = []

        for run in runs {
            guard let text = (run["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  !ParsingHelpers.isArtistSeparator(text)
            else { continue }

            if let browseId = Self.browseId(of: run) {
                if Artist.isNavigableId(browseId) {
                    linked.append(Artist(id: browseId, name: text))
                }
                // Any other link in a byline is a page, not an artist: the album's own run is one.
                continue
            }

            guard !ParsingHelpers.isMetadataText(text),
                  !(albumTitle.map { Self.isSameName(text, $0) } ?? false)
            else { continue }

            plain.append(text)
        }

        if !linked.isEmpty { return linked }

        return plain.map { name in
            Artist(id: ParsingHelpers.stableId(title: "artist", components: name), name: name)
        }
    }

    /// Whether two names are the same name, ignoring case, diacritics and surrounding space.
    private static func isSameName(_ lhs: String, _ rhs: String) -> Bool {
        func canonical(_ name: String) -> String {
            name.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.diacriticInsensitive], locale: .current)
                .lowercased()
        }
        let left = canonical(lhs)
        return !left.isEmpty && left == canonical(rhs)
    }

    /// The browse ID a byline run links to, when it links to a page.
    private static func browseId(of run: [String: Any]) -> String? {
        guard let navigation = run["navigationEndpoint"] as? [String: Any],
              let browse = navigation["browseEndpoint"] as? [String: Any]
        else { return nil }
        return browse["browseId"] as? String
    }

    /// Parses the thumbnail URL from the panel video renderer.
    static func parseThumbnail(from renderer: [String: Any]) -> URL? {
        guard let thumbnail = renderer["thumbnail"] as? [String: Any],
              let thumbnails = thumbnail["thumbnails"] as? [[String: Any]],
              let lastThumb = thumbnails.last,
              let urlString = lastThumb["url"] as? String
        else { return nil }

        let normalizedURL = urlString.hasPrefix("//") ? "https:" + urlString : urlString
        return URL(string: normalizedURL)
    }

    /// Parses the duration from the panel video renderer.
    static func parseDuration(from renderer: [String: Any]) -> TimeInterval? {
        guard let lengthText = renderer["lengthText"] as? [String: Any],
              let runs = lengthText["runs"] as? [[String: Any]],
              let firstRun = runs.first,
              let text = firstRun["text"] as? String
        else { return nil }

        return ParsingHelpers.parseDuration(text)
    }

    /// Parses the music video type from the panel video renderer's navigation endpoint.
    /// Path: navigationEndpoint.watchEndpoint.watchEndpointMusicSupportedConfigs.watchEndpointMusicConfig.musicVideoType
    static func parseMusicVideoType(from renderer: [String: Any]) -> MusicVideoType? {
        guard let navEndpoint = renderer["navigationEndpoint"] as? [String: Any],
              let watchEndpoint = navEndpoint["watchEndpoint"] as? [String: Any],
              let configs = watchEndpoint["watchEndpointMusicSupportedConfigs"] as? [String: Any],
              let musicConfig = configs["watchEndpointMusicConfig"] as? [String: Any],
              let typeString = musicConfig["musicVideoType"] as? String
        else { return nil }

        return MusicVideoType(rawValue: typeString)
    }

    /// Parses menu data (feedbackTokens, library status) from the panel video renderer.
    static func parseMenuData(from renderer: [String: Any]) -> MenuParseResult {
        var result = MenuParseResult(feedbackTokens: nil, isInLibrary: false)

        guard let menu = renderer["menu"] as? [String: Any],
              let menuRenderer = menu["menuRenderer"] as? [String: Any],
              let items = menuRenderer["items"] as? [[String: Any]]
        else { return result }

        for item in items {
            self.parseMenuServiceItem(item, into: &result)
            self.parseToggleMenuItem(item, into: &result)
        }

        return result
    }

    /// Parses the rating of the video the player holds.
    ///
    /// The like button is not in the panel row's menu — its `topLevelButtons` is empty on a real
    /// `next` response. It is in the player overlays, which describe the video being played:
    /// `playerOverlays.playerOverlayRenderer.actions[].likeButtonRenderer.likeStatus`. That is the
    /// rating YouTube Music shows on its own transport, and the one the app's transport draws.
    static func parseLikeStatus(from data: [String: Any]) -> LikeStatus? {
        guard let overlays = data["playerOverlays"] as? [String: Any],
              let overlayRenderer = overlays["playerOverlayRenderer"] as? [String: Any],
              let actions = overlayRenderer["actions"] as? [[String: Any]]
        else { return nil }

        for action in actions {
            guard let likeButtonRenderer = action["likeButtonRenderer"] as? [String: Any],
                  let status = likeButtonRenderer["likeStatus"] as? String
            else { continue }

            return switch status {
            case "LIKE": .like
            case "DISLIKE": .dislike
            default: .indifferent
            }
        }

        return nil
    }

    /// Parses a menuServiceItemRenderer for library tokens.
    private static func parseMenuServiceItem(_ item: [String: Any], into result: inout MenuParseResult) {
        guard let menuServiceItem = item["menuServiceItemRenderer"] as? [String: Any],
              let icon = menuServiceItem["icon"] as? [String: Any],
              let iconType = icon["iconType"] as? String
        else { return }

        let token = self.extractFeedbackToken(from: menuServiceItem, key: "serviceEndpoint")

        switch iconType {
        case "LIBRARY_ADD", "BOOKMARK_BORDER":
            if let token { result.feedbackTokens = FeedbackTokens(add: token, remove: nil) }
        case "LIBRARY_REMOVE", "BOOKMARK":
            result.isInLibrary = true
            if let token { result.feedbackTokens = FeedbackTokens(add: nil, remove: token) }
        default:
            break
        }
    }

    /// Parses a toggleMenuServiceItemRenderer for library tokens.
    private static func parseToggleMenuItem(_ item: [String: Any], into result: inout MenuParseResult) {
        guard let toggleItem = item["toggleMenuServiceItemRenderer"] as? [String: Any],
              let defaultIcon = toggleItem["defaultIcon"] as? [String: Any],
              let iconType = defaultIcon["iconType"] as? String
        else { return }

        let defaultToken = self.extractFeedbackToken(from: toggleItem, key: "defaultServiceEndpoint")
        let toggledToken = self.extractFeedbackToken(from: toggleItem, key: "toggledServiceEndpoint")

        if iconType == "LIBRARY_ADD" || iconType == "BOOKMARK_BORDER" {
            result.feedbackTokens = FeedbackTokens(add: defaultToken, remove: toggledToken)
        } else if iconType == "LIBRARY_REMOVE" || iconType == "BOOKMARK" {
            result.isInLibrary = true
            result.feedbackTokens = FeedbackTokens(add: toggledToken, remove: defaultToken)
        }
    }

    /// Extracts a feedback token from a service endpoint.
    private static func extractFeedbackToken(from dict: [String: Any], key: String) -> String? {
        guard let endpoint = dict[key] as? [String: Any],
              let feedback = endpoint["feedbackEndpoint"] as? [String: Any]
        else { return nil }
        return feedback["feedbackToken"] as? String
    }

}
