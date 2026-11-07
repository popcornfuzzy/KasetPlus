import Foundation

// MARK: - ArtistLogo

/// An artist's wordmark, as Apple Music draws it at the top of their artist page.
///
/// `aspectRatio` is width over height, so the header can size a transparent PNG before it decodes.
struct ArtistLogo: Sendable, Equatable {
    let url: URL
    let aspectRatio: CGFloat
}

// MARK: - AppleArtistLogoService

/// Finds an artist's wordmark logo from nothing but their name.
///
/// YouTube Music does not publish artist logos, but Apple Music's artist pages do: a transparent PNG
/// in the page's hydration JSON. This service turns a name into an Apple Music artist id with the
/// public iTunes search API, proves the Apple artist is the same act by sharing a release title with
/// the YouTube page, and then reads the logo from the artist's own music.apple.com page.
///
/// A name is not an identity: Apple has a "Krsna" who is not YouTube's KR$NA, and the search will
/// happily return either. A same-named Apple artist is only taken when its albums share a title with
/// the YouTube page's own, which is why `catalogueTitles` is required — without evidence nothing is
/// asked for. Found wordmarks live in memory and on disk for a month; a miss is never remembered, so an
/// artist whose logo Apple adds later picks it up on the next visit. Nothing here throws to the caller:
/// a failure to look up is never a failure to show the page, which falls back to the artist's name.
actor AppleArtistLogoService {
    static let shared = AppleArtistLogoService()

    private static let searchURL = "https://itunes.apple.com/search"
    private static let lookupURL = "https://itunes.apple.com/lookup"
    /// Width the logo is requested at. Apple's template takes any size; 1000 px covers a Retina header.
    private static let logoPixelWidth = 1000
    private static let maxCachedLogos = 128
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

    /// Found logos only. A miss is deliberately not remembered here *or* on disk, so a logo Apple adds
    /// later is picked up on the next visit rather than never.
    private var cache: [String: ArtistLogo] = [:]
    private let session: URLSession
    private let diskCache: ArtistLogoCache

    init(session: URLSession = .shared, diskCache: ArtistLogoCache = .shared) {
        self.session = session
        self.diskCache = diskCache
    }

    // MARK: - Lookup

    /// The wordmark for the YouTube artist `name`, or nil when Apple has none — or none that provably
    /// is this artist. `catalogueTitles` are the page's own song and release titles, and `artistId` is
    /// the YouTube browse id: two channels with one name can deserve different answers, so the answer
    /// is remembered per channel rather than per name.
    func logo(forArtistNamed name: String, identifiedBy artistId: String, catalogueTitles: [String]) async -> ArtistLogo? {
        let normalizedName = CanvasMatching.normalizeForComparison(name)
        guard !normalizedName.isEmpty else { return nil }
        let key = artistId.isEmpty ? normalizedName : artistId

        if let cached = self.cache[key] {
            return cached
        }

        // A wordmark found in an earlier session is on disk for a month.
        if let cached = await self.diskCache.logo(for: key) {
            self.cache[key] = cached
            return cached
        }

        let titles = Set(catalogueTitles.map(CanvasMatching.normalizeForComparison).filter { !$0.isEmpty })
        // No titles means no evidence, and a same-named artist with different music is worse than none.
        guard !titles.isEmpty else { return nil }

        do {
            guard let logo = try await self.lookup(artistName: name, key: normalizedName, titles: titles) else {
                return nil
            }
            self.store(logo, for: key)
            await self.diskCache.store(logo, for: key)
            return logo
        } catch {
            DiagnosticsLogger.api.debug(
                "Apple artist logo lookup failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func lookup(artistName: String, key: String, titles: Set<String>) async throws -> ArtistLogo? {
        let candidates = try await self.artistCandidates(named: artistName, key: key)
        for candidate in candidates {
            let albums = try await self.albumTitles(forArtistId: candidate.id)
            guard Self.sharesTitles(albums, titles) else {
                DiagnosticsLogger.api.debug(
                    "Apple artist \(candidate.id, privacy: .public) shares no titles with \(artistName, privacy: .public), skipped"
                )
                continue
            }
            guard let html = try await self.artistPage(at: candidate.pageURL) else { continue }
            return Self.artistLogo(inHTML: html)
        }
        return nil
    }

    private func store(_ logo: ArtistLogo, for key: String) {
        if self.cache.count >= Self.maxCachedLogos {
            self.cache.removeAll()
        }
        self.cache[key] = logo
    }

    // MARK: - Requests

    private struct Candidate {
        let id: Int
        let pageURL: URL
    }

    private func artistCandidates(named name: String, key: String) async throws -> [Candidate] {
        guard var components = URLComponents(string: Self.searchURL) else { return [] }
        components.queryItems = [
            URLQueryItem(name: "term", value: name),
            URLQueryItem(name: "entity", value: "musicArtist"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components.url else { return [] }

        let results = try await self.json(at: url)["results"] as? [[String: Any]] ?? []
        return results.compactMap { result in
            guard let artistName = result["artistName"] as? String,
                  CanvasMatching.normalizeForComparison(artistName) == key,
                  let id = result["artistId"] as? Int
            else { return nil }

            let link = (result["artistLinkUrl"] as? String)?.components(separatedBy: "?").first
            let pageURL = link.flatMap { URL(string: $0) }
                ?? URL(string: "https://music.apple.com/us/artist/\(id)")
            guard let pageURL else { return nil }
            return Candidate(id: id, pageURL: pageURL)
        }
    }

    /// The artist's album titles on Apple Music, the evidence that this artist is the same act.
    private func albumTitles(forArtistId id: Int) async throws -> [String] {
        guard var components = URLComponents(string: Self.lookupURL) else { return [] }
        components.queryItems = [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "50"),
        ]
        guard let url = components.url else { return [] }

        let results = try await self.json(at: url)["results"] as? [[String: Any]] ?? []
        return results.compactMap { $0["collectionName"] as? String }
    }

    private func artistPage(at url: URL) async throws -> String? {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25
        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func json(at url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return root
    }

    // MARK: - Parsing (internal for tests)

    /// Reads the artist's wordmark out of a `music.apple.com` artist page.
    ///
    /// The page embeds a `serialized-server-data` JSON blob for hydration; the header node inside it is
    /// the only one carrying an `artistLogo` key, and the key is `null` for the many artists without a
    /// wordmark. The JSON is not an API Apple publishes, so every surprise reads as "no logo".
    static func artistLogo(inHTML html: String) -> ArtistLogo? {
        guard let json = serializedServerData(in: html),
              let root = try? JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed]),
              let header = firstNode(withKey: "artistLogo", in: root),
              let logo = header["artistLogo"] as? [String: Any],
              let artwork = logo["dictionary"] as? [String: Any],
              let template = artwork["url"] as? String,
              let width = artwork["width"] as? Int,
              let height = artwork["height"] as? Int,
              width > 0, height > 0,
              let url = self.artworkURL(
                  template: template,
                  width: self.logoPixelWidth,
                  height: self.logoPixelWidth * height / width
              )
        else { return nil }

        return ArtistLogo(url: url, aspectRatio: CGFloat(width) / CGFloat(height))
    }

    /// Fills Apple's artwork template: `{w}` and `{h}` size it, `{c}` picks the crop and `{f}` the format.
    static func artworkURL(template: String, width: Int, height: Int) -> URL? {
        guard template.contains("{w}"), template.contains("{h}"), width > 0, height > 0 else { return nil }
        let filled = template
            .replacingOccurrences(of: "{w}", with: String(width))
            .replacingOccurrences(of: "{h}", with: String(height))
            .replacingOccurrences(of: "{c}", with: "bb")
            .replacingOccurrences(of: "{f}", with: "png")
        guard let url = URL(string: filled), url.scheme == "https" else { return nil }
        return url
    }

    /// Whether two catalogues name a common release. Normalized first, so punctuation and casing do not
    /// hide `Currents` behind `currents`.
    static func sharesTitles(_ lhs: [String], _ rhs: Set<String>) -> Bool {
        lhs.contains { rhs.contains(CanvasMatching.normalizeForComparison($0)) }
    }

    private static func serializedServerData(in html: String) -> Data? {
        guard let marker = html.range(of: "id=\"serialized-server-data\"") else { return nil }
        guard let open = html[marker.upperBound...].firstIndex(of: ">"),
              let close = html[html.index(after: open)...].range(of: "</script>")
        else { return nil }
        return String(html[html.index(after: open)..<close.lowerBound]).data(using: .utf8)
    }

    /// The first object anywhere in `node` that carries `key`.
    private static func firstNode(withKey key: String, in node: Any) -> [String: Any]? {
        if let dictionary = node as? [String: Any] {
            if dictionary[key] != nil { return dictionary }
            for value in dictionary.values {
                if let found = self.firstNode(withKey: key, in: value) { return found }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let found = self.firstNode(withKey: key, in: value) { return found }
            }
        }
        return nil
    }
}
