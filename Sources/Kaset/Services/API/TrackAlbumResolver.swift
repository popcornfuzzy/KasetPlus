import Foundation

/// Finds the album a track belongs to when YouTube Music names the track's own single as its album.
///
/// YouTube Music reports a release it only carries as a single under the track's own title: playing
/// "Flowers" names the album "Flowers", and that page holds one song, while the track is also on
/// `Endless Summer Vacation`. Kaset opens whatever album a track carries, so that page stood in for the
/// album and the title opened a single posing as one. The album is found by asking for the track on
/// the artist's releases and *proving* the track is on one: a page whose listing holds the song and
/// holds more than that one song. When nothing proves it, the reported album is left alone — a wrong
/// album is worse than the one YouTube Music named.
enum TrackAlbumResolver {
    /// Caps the album pages read per lookup, so a miss cannot fan out into an unbounded number of
    /// requests.
    static let maxAlbumLookups = 5

    /// The catalog search that finds an album a track is on.
    ///
    /// The track's title belongs in the query: an artist-only album search ranks a discography by
    /// popularity, which put the real album fourth for "Flowers" and past what is worth reading, while
    /// "<artist> <track>" leads with the album that holds it.
    static func searchQuery(trackTitle: String, artist: String) -> String {
        [artist, trackTitle]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Whether a track's reported album is the track's own single.
    ///
    /// The byline's album run carries the track's title, sometimes with a `- Single` / `- EP` suffix.
    /// An album genuinely named after its title track looks the same, which is why the replacement is
    /// verified against the album's track list before it is used (see ``resolve``).
    static func needsResolution(albumTitle: String, trackTitle: String) -> Bool {
        let album = self.comparable(albumTitle)
        let track = self.comparable(trackTitle)
        guard !album.isEmpty, !track.isEmpty else { return false }
        // Some storefronts suffix the release kind onto the title the byline shows.
        let release = album
            .replacingOccurrences(of: #"\s*[-–—]\s*(single|ep)$"#, with: "", options: .regularExpression)
        return release == track
    }

    /// Albums worth reading a page for: navigable, and either credited to one of the track's artists or
    /// carrying no credits at all.
    ///
    /// A filtered search row names an album's page and its artist in the subtitle but parses no artists
    /// into the album, so an empty credit is "not known here", not "someone else": the page read in
    /// ``resolve`` checks the credits it does expose.
    static func candidates(from albums: [Album], artist: String) -> [Album] {
        let requested = self.artistNames(in: artist)
        return albums.filter { album in
            guard album.hasNavigableId else { return false }
            let credited = self.artistNames(in: album.artistsDisplay)
            return credited.isEmpty || requested.isEmpty || !credited.isDisjoint(with: requested)
        }
    }

    /// The album whose page proves it holds the song, or `nil` when none does.
    ///
    /// - Parameters:
    ///   - searchAlbums: The artist's albums, from a filtered catalog search.
    ///   - albumPage: One album page, read for its credits and track list.
    static func resolve(
        trackTitle: String,
        artist: String,
        searchAlbums: @Sendable (String) async throws -> [Album],
        albumPage: @Sendable (String) async throws -> PlaylistDetail
    ) async -> Album? {
        guard let albums = try? await searchAlbums(Self.searchQuery(trackTitle: trackTitle, artist: artist))
        else { return nil }
        let requested = self.artistNames(in: artist)

        for candidate in Self.candidates(from: albums, artist: artist).prefix(Self.maxAlbumLookups) {
            if Task.isCancelled { return nil }
            guard let page = try? await albumPage(candidate.id) else { continue }
            // A single is what is being replaced, so a page holding only this one song is not the album.
            guard page.tracks.count > 1,
                  page.tracks.contains(where: { Self.titlesMatch($0.title, trackTitle) })
            else { continue }
            // The page's own credits must name one of the track's artists, when it names any. A covers
            // album of the same song is rejected here.
            let credited = Set(page.artists.map(\.name).map { Self.comparable($0) })
            if !credited.isEmpty, !requested.isEmpty, credited.isDisjoint(with: requested) { continue }

            return Album(
                id: page.id,
                title: page.title,
                artists: page.artists.isEmpty ? candidate.artists : page.artists,
                thumbnailURL: page.thumbnailURL ?? candidate.thumbnailURL,
                year: candidate.year,
                trackCount: page.trackCount ?? page.tracks.count
            )
        }
        return nil
    }

    /// Whether two titles name the same song, ignoring case, diacritics and spacing.
    static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = self.comparable(lhs)
        return !left.isEmpty && left == self.comparable(rhs)
    }

    /// A string reduced to what two catalogs agree on: case, accents and spacing.
    private static func comparable(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The individual names in a credit line.
    private static func artistNames(in text: String) -> Set<String> {
        Set(
            text.split(whereSeparator: { $0 == "," || $0 == "&" })
                .map { Self.comparable(String($0)) }
                .filter { !$0.isEmpty }
        )
    }
}
