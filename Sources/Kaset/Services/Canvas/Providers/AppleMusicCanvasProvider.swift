import Foundation

/// Fetches Apple Music album motion artwork (HLS canvas) for the fullscreen
/// view. The catalog access token is discovered at runtime from the Apple Music
/// web player scripts — no credentials are embedded in the binary.
///
/// Apple Music keys motion artwork to the **album**, and it may only come from the
/// album the track is on. The artist resource also carries an `editorialVideo`, but
/// that one is the artist's current spotlight — in practice the newest release — so
/// reading it painted a new album's canvas over old songs that are not on that album.
///
/// The album is found through Apple's own record of the **song**: its search result
/// names the album and its URL carries that album's id. Album *search* is not used for
/// discovery — it ranks differently per storefront and can miss the album entirely
/// ("Drake Jimmy Cooks" in the Austrian storefront returns Drake singles, not
/// `Honestly, Nevermind`) — and YouTube Music cannot be trusted to name the album
/// either, because it reports a single as the album when the track leads one
/// (Flowers reports its own title as the album). Whatever the source, the album has to
/// prove it holds the song before its motion artwork is used.
final class AppleMusicCanvasProvider: CanvasProvider {
    let name = "Apple Music"

    private static let ampBaseURL = "https://amp-api.music.apple.com"
    private static let musicAppleBaseURL = "https://music.apple.com"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Caps the album requests per lookup, so a miss cannot fan out into an
    /// unbounded number of network round trips.
    private static let maxAlbumLookups = 3

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration)
    }()

    private let tokenStore = TokenStore()

    // MARK: - CanvasProvider

    func fetchCanvas(for info: CanvasSearchInfo) async -> CanvasArtwork? {
        let song = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !song.isEmpty else { return nil }
        let storefront = Self.storefrontCode()
        guard let token = await self.tokenStore.token() else {
            DiagnosticsLogger.api.error("Apple Music canvas: no web player token available")
            return nil
        }

        let artist = info.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = info.album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // 1. Apple's record of the song names its album and links it.
        let term = [artist, song].filter { !$0.isEmpty }.joined(separator: " ")
        let songs = await self.searchSongs(term: term, storefront: storefront, token: token)
        let albumIds = Self.albumIds(from: songs, song: song, artist: artist, limit: Self.maxAlbumLookups)
        DiagnosticsLogger.api.debug(
            "Apple Music canvas: song \"\(song, privacy: .public)\" named \(albumIds.count) album(s)"
        )
        for albumId in albumIds {
            if Task.isCancelled { return nil }
            if let artwork = await Self.fetchAlbumArtwork(
                albumId: albumId,
                song: song,
                storefront: storefront,
                token: token
            ) {
                return artwork
            }
        }

        // 2. The reported album itself, when its page carries motion artwork. This
        //    covers a track Apple's search cannot find but whose album it lists.
        guard !album.isEmpty else { return nil }
        let albumTerm = [artist, album].filter { !$0.isEmpty }.joined(separator: " ")
        let albums = await self.searchAlbums(term: albumTerm, storefront: storefront, token: token)
        let candidates = Self.albumCandidates(from: albums, song: song, artist: artist, album: album)
        for candidate in candidates.prefix(Self.maxAlbumLookups) {
            if Task.isCancelled { return nil }
            if let artwork = await Self.fetchAlbumArtwork(
                albumId: candidate.id,
                song: song,
                storefront: storefront,
                token: token
            ) {
                return artwork
            }
        }
        return nil
    }

    // MARK: - Song record

    /// One song from a catalog search: the album the track is on is named on it and
    /// linked from its URL.
    struct SongSearchResult: Equatable {
        let id: String
        let name: String
        let artistName: String
        let url: URL?
    }

    /// The albums of the search results that are this track, best first.
    ///
    /// Several releases of one song can come back (a single, then the album it appears
    /// on), so every matching result's album is offered; the album that proves it holds
    /// the song and carries motion artwork is the one that answers.
    static func albumIds(
        from songs: [SongSearchResult],
        song: String,
        artist: String,
        limit: Int = 3
    ) -> [String] {
        var ids: [String] = []
        for result in songs {
            guard Self.artistMatches(validation: artist, returned: result.artistName),
                  Self.trackTitleMatches(result.name, song),
                  let albumId = Self.albumId(fromSongURL: result.url)
            else { continue }
            guard !ids.contains(albumId) else { continue }
            ids.append(albumId)
            if ids.count >= limit { break }
        }
        return ids
    }

    /// The album id in a song's web URL, e.g.
    /// `https://music.apple.com/at/album/flowers/1674691585?i=1674691586`.
    static func albumId(fromSongURL url: URL?) -> String? {
        guard let url,
              let range = url.path.range(of: #"/album/[^/]+/\d+"#, options: .regularExpression)
        else { return nil }
        return url.path[range].split(separator: "/").last.map(String.init)
    }

    /// Reads the song results of a catalog search response.
    static func songSearchResults(from json: [String: Any]) -> [SongSearchResult] {
        guard let results = json["results"] as? [String: Any],
              let songs = results["songs"] as? [String: Any],
              let data = songs["data"] as? [[String: Any]]
        else { return [] }
        return data.compactMap { obj in
            guard let id = obj["id"] as? String,
                  let attributes = obj["attributes"] as? [String: Any],
                  let name = attributes["name"] as? String
            else { return nil }
            return SongSearchResult(
                id: id,
                name: name,
                artistName: attributes["artistName"] as? String ?? "",
                url: (attributes["url"] as? String).flatMap(URL.init(string:))
            )
        }
    }

    private func searchSongs(term: String, storefront: String, token: String) async -> [SongSearchResult] {
        guard !term.isEmpty else { return [] }
        let json = await Self.search(term: term, types: "songs", storefront: storefront, token: token)
        return Self.songSearchResults(from: json)
    }

    // MARK: - Fallback album search

    /// One album from a catalog search.
    struct AlbumSearchResult: Equatable {
        let id: String
        let name: String
        let artistName: String
    }

    /// Search results that may supply the canvas, best first: the reported album,
    /// then a release titled after the song. Everything else is dropped — an artist's
    /// other albums must never stand in for the track's album.
    static func albumCandidates(
        from results: [AlbumSearchResult],
        song: String,
        artist: String,
        album: String
    ) -> [AlbumSearchResult] {
        results.enumerated().compactMap { index, result -> (rank: Int, index: Int, result: AlbumSearchResult)? in
            guard Self.artistMatches(validation: artist, returned: result.artistName),
                  let rank = Self.albumRank(result.name, song: song, album: album)
            else { return nil }
            return (rank, index, result)
        }
        .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
        .map(\.result)
    }

    /// How well an album title fits the track: the reported album, a release named
    /// after the song, or not at all (`nil`).
    static func albumRank(_ name: String, song: String, album: String) -> Int? {
        let title = CanvasMatching.normalizeForComparison(name)
        guard !title.isEmpty else { return nil }
        if Self.albumTitleMatches(title, CanvasMatching.normalizeForComparison(album)) {
            return 0
        }
        return Self.albumTitleMatches(title, CanvasMatching.normalizeForComparison(song)) ? 1 : nil
    }

    /// Whether an album title is the expected release. Apple decorates a single's
    /// album title with a `- Single` / `- EP` suffix the other catalogs leave off
    /// ("Good Days - Single" for the track "Good Days"), so that suffix is tolerated
    /// — nothing else is.
    private static func albumTitleMatches(_ title: String, _ expected: String) -> Bool {
        guard !expected.isEmpty else { return false }
        return title == expected || title == expected + " single" || title == expected + " ep"
    }

    /// Reads the album results of a catalog search response.
    static func albumSearchResults(from json: [String: Any]) -> [AlbumSearchResult] {
        guard let results = json["results"] as? [String: Any],
              let albums = results["albums"] as? [String: Any],
              let data = albums["data"] as? [[String: Any]]
        else { return [] }
        return data.compactMap { obj in
            guard let id = obj["id"] as? String,
                  let attributes = obj["attributes"] as? [String: Any],
                  let name = attributes["name"] as? String
            else { return nil }
            return AlbumSearchResult(
                id: id,
                name: name,
                artistName: attributes["artistName"] as? String ?? ""
            )
        }
    }

    private func searchAlbums(term: String, storefront: String, token: String) async -> [AlbumSearchResult] {
        let json = await Self.search(term: term, types: "albums", storefront: storefront, token: token)
        return Self.albumSearchResults(from: json)
    }

    /// Searches the catalog for one resource type.
    private static func search(term: String, types: String, storefront: String, token: String) async -> [String: Any] {
        guard !term.isEmpty,
              var components = URLComponents(string: "\(Self.ampBaseURL)/v1/catalog/\(storefront)/search")
        else { return [:] }
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "types", value: types),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components.url else { return [:] }
        var request = URLRequest(url: url)
        Self.applyAMPHeaders(to: &request, token: token)

        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return json
        } catch {
            return [:]
        }
    }

    /// Whether the album is credited to one of the track's artists. A blank request
    /// passes: no artist constraint was asked for.
    ///
    /// Any shared credit is enough. Apple's album `artistName` names the release's
    /// lead artist, so a collaboration on that artist's album — "Drake, 21 Savage" on
    /// `Honestly, Nevermind`, which is credited to "Drake" alone — has to match on the
    /// lead: requiring every track credit rejected each of those tracks and left them
    /// without a canvas. The album's track list is what proves the song; this check
    /// only keeps a same-titled album by an unrelated act away.
    static func artistMatches(validation: String, returned: String) -> Bool {
        let requested = Set(CanvasMatching.artistComponents(validation))
        guard !requested.isEmpty else { return true }
        let names = Set(CanvasMatching.artistComponents(returned))
        guard !names.isEmpty else { return false }
        return !requested.isDisjoint(with: names)
    }

    // MARK: - Token discovery

    private static func storefrontCode() -> String {
        guard let region = Locale.current.region?.identifier, region.count == 2 else {
            return "us"
        }
        return region.lowercased()
    }

    /// A discovered web player JWT and its expiry (epoch milliseconds).
    struct DiscoveredToken: Equatable {
        let token: String
        let expiryMs: Int64
    }

    /// Caches the discovered token in an actor so concurrent lookups share one
    /// discovery pass.
    private actor TokenStore {
        private var cachedToken: String?
        private var tokenExpiryMs: Int64 = 0

        func token() async -> String? {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            if let cachedToken, nowMs < self.tokenExpiryMs - 60000 {
                return cachedToken
            }
            guard let discovered = await AppleMusicCanvasProvider.fetchWebPlayerToken(),
                  discovered.expiryMs > nowMs
            else { return nil }
            self.cachedToken = discovered.token
            self.tokenExpiryMs = discovered.expiryMs
            return discovered.token
        }
    }

    /// Scrapes a fresh web player JWT from the Apple Music web player scripts.
    static func fetchWebPlayerToken() async -> DiscoveredToken? {
        do {
            let browseURL = URL(string: "\(Self.musicAppleBaseURL)/us/browse")!
            var browseRequest = URLRequest(url: browseURL)
            browseRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let (html, response) = try await Self.session.data(for: browseRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let htmlString = String(data: html, encoding: .utf8)
            else { return nil }

            let scriptRegex = try NSRegularExpression(pattern: #"/assets/index(?:-legacy)?[~-][a-zA-Z0-9_-]+\.js"#)
            let scriptPaths = Self.matches(scriptRegex, in: htmlString)
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

            for scriptPath in scriptPaths {
                let scriptURL = URL(string: "\(Self.musicAppleBaseURL)\(scriptPath)")!
                var scriptRequest = URLRequest(url: scriptURL)
                scriptRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                let (data, scriptResponse) = try await Self.session.data(for: scriptRequest)
                guard let http = scriptResponse as? HTTPURLResponse,
                      http.statusCode == 200,
                      let script = String(data: data, encoding: .utf8)
                else { continue }

                let tokenRegex = try NSRegularExpression(pattern: #"ey[a-zA-Z0-9_-]+\.ey[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+"#)
                for token in Self.matches(tokenRegex, in: script) {
                    if let discovered = Self.validateToken(token, nowMs: nowMs) {
                        return discovered
                    }
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Validates a JWT-shaped token by decoding its payload and checking for an
    /// `iss` claim plus an unexpired `exp`. Pure function for unit tests.
    static func validateToken(_ token: String, nowMs: Int64) -> DiscoveredToken? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        guard let decoded = Self.decodeBase64URL(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any]
        else { return nil }
        guard json["iss"] != nil else { return nil }
        guard let exp = json["exp"] as? NSNumber, exp.int64Value * 1000 > nowMs else { return nil }
        return DiscoveredToken(token: token, expiryMs: exp.int64Value * 1000)
    }

    /// Decodes a base64url (JWT-safe alphabet) string.
    static func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        return Data(base64Encoded: base64)
    }

    private static func matches(_ regex: NSRegularExpression, in string: String) -> [String] {
        let range = NSRange(string.startIndex..., in: string)
        return regex.matches(in: string, range: range).compactMap { match in
            Range(match.range, in: string).map { String(string[$0]) }
        }
    }

    // MARK: - Album lookup

    /// Fetches an album with its motion artwork extensions and track list, and
    /// builds the canvas only when the album holds the requested song.
    static func fetchAlbumArtwork(
        albumId: String,
        song: String,
        storefront: String,
        token: String
    ) async -> CanvasArtwork? {
        guard var components = URLComponents(
            string: "\(Self.ampBaseURL)/v1/catalog/\(storefront)/albums/\(albumId)"
        ) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "extend", value: "editorialVideo,editorialArtwork"),
            URLQueryItem(name: "include", value: "tracks"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        Self.applyAMPHeaders(to: &request, token: token)

        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let album = (json["data"] as? [[String: Any]])?.first
            else { return nil }
            guard let artwork = Self.artwork(fromAlbum: album, song: song) else {
                DiagnosticsLogger.api.debug(
                    "Apple Music canvas: album \(albumId, privacy: .public) has no verified motion artwork for \"\(song, privacy: .public)\""
                )
                return nil
            }
            return artwork
        } catch {
            return nil
        }
    }

    /// Builds the canvas for an album resource, refusing it unless the album's
    /// included tracks list the song: the motion artwork belongs to the album, so an
    /// album that does not contain the track must never supply it.
    static func artwork(fromAlbum album: [String: Any], song: String) -> CanvasArtwork? {
        guard let attributes = album["attributes"] as? [String: Any],
              Self.albumContainsSong(album, title: song),
              let videoURL = Self.extractEditorialVideoURL(from: attributes)
        else { return nil }
        return CanvasArtwork(
            name: song,
            artist: attributes["artistName"] as? String,
            videoURL: videoURL,
            source: "Apple Music",
            albumName: attributes["name"] as? String
        )
    }

    /// Whether an album resource's included `tracks` relationship lists the title.
    static func albumContainsSong(_ album: [String: Any], title: String) -> Bool {
        guard !CanvasMatching.normalizeForComparison(title).isEmpty,
              let relationships = album["relationships"] as? [String: Any],
              let tracks = relationships["tracks"] as? [String: Any],
              let data = tracks["data"] as? [[String: Any]]
        else { return false }
        for track in data {
            guard let attributes = track["attributes"] as? [String: Any],
                  let trackTitle = attributes["name"] as? String
            else { continue }
            if Self.trackTitleMatches(trackTitle, title) { return true }
        }
        return false
    }

    /// Whether an album track title names the requested song, tolerating a
    /// featured-artist credit. Apple appends one to the album's own track listing
    /// ("Jimmy Cooks (feat. 21 Savage)") where YouTube Music's title may be just
    /// "Jimmy Cooks", and requiring the bare titles rejected every collaboration.
    /// Only a `feat`/`ft`/`featuring` credit is ignored — a word such as "with" is
    /// part of a title ("Dance With Me") and must keep counting.
    static func trackTitleMatches(_ candidate: String, _ requested: String) -> Bool {
        let candidateTitle = CanvasMatching.normalizeForComparison(candidate)
        let requestedTitle = CanvasMatching.normalizeForComparison(requested)
        guard !candidateTitle.isEmpty, !requestedTitle.isEmpty else { return false }
        if candidateTitle == requestedTitle { return true }
        let left = Self.removingFeatureCredit(candidateTitle)
        let right = Self.removingFeatureCredit(requestedTitle)
        return !left.isEmpty && !right.isEmpty && left == right
    }

    /// A normalized title without its trailing featured-artist credit.
    private static func removingFeatureCredit(_ normalizedTitle: String) -> String {
        guard let range = normalizedTitle.range(
            of: #"\s+(feat|ft|featuring)\s+"#,
            options: .regularExpression
        ) else { return normalizedTitle }
        return String(normalizedTitle[normalizedTitle.startIndex ..< range.lowerBound])
    }

    private static func applyAMPHeaders(to request: inout URLRequest, token: String) {
        request.timeoutInterval = 25
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    }

    // MARK: - Motion video extraction (internal for unit tests)

    /// Extracts the motion video URL from a resource's attributes, preferring
    /// `editorialVideo` over `editorialArtwork`.
    static func extractEditorialVideoURL(from attributes: [String: Any]) -> URL? {
        if let editorialVideo = attributes["editorialVideo"] as? [String: Any],
           let url = Self.videoURL(in: editorialVideo)
        {
            return url
        }
        if let editorialArtwork = attributes["editorialArtwork"] as? [String: Any],
           let url = Self.videoURL(in: editorialArtwork)
        {
            return url
        }
        return nil
    }

    /// Finds a motion video URL inside an editorial data object, honoring the
    /// preferred key order before falling back to any nested `video` string.
    static func videoURL(in editorialData: [String: Any]) -> URL? {
        let preferredKeys = [
            "motionDetailRaw",
            "motionDetailTall",
            "motionDetailSquare",
            "motionSquareVideo1x1",
            "motionTallVideo3x4",
        ]
        for key in preferredKeys {
            if let video = (editorialData[key] as? [String: Any])?["video"] as? String,
               let url = Self.validVideoURL(video)
            {
                return url
            }
        }
        for (_, value) in editorialData {
            if let dict = value as? [String: Any],
               let video = dict["video"] as? String,
               let url = Self.validVideoURL(video)
            {
                return url
            }
        }
        return nil
    }

    private static func validVideoURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return url
    }
}
