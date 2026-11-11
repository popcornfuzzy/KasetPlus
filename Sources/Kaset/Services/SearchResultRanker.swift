import Foundation

// MARK: - SearchResultRanker

/// Keeps YouTube Music's own search order and folds a track's duplicate music-video row into it.
///
/// YouTube Music already ranks a search: the "Top result" card comes first, then each shelf in turn.
/// Flattening that into songs/albums/artists/playlists put the card's music video above the album
/// version and pushed every artist below every song. `SearchResponse.allItems` now keeps the API's
/// order, so the only thing left to do is drop the duplicate: a flat row list would show a song and
/// its music video as two identical rows, where YouTube Music draws the card as a large hero.
/// `topResult(_:)` supplies that hero, and the row the card would have been is left out of the list.
@MainActor
enum SearchResultRanker {
    /// The API's order, with each song's video/audio pair collapsed into the album version.
    ///
    /// When the response has a top-result card, its row is left out: the card draws it as a hero
    /// above the list, and the parser puts the card first.
    static func ranked(_ response: SearchResponse) -> [SearchResultItem] {
        let collapsed = self.collapsingVariants(response.allItems)
        guard response.topResult != nil, !collapsed.isEmpty else { return collapsed }
        return Array(collapsed.dropFirst())
    }

    /// The hero card's content: the card's item, standing as the album version when the card is a
    /// track's official music video.
    static func topResult(_ response: SearchResponse) -> SearchTopResult? {
        guard let card = response.topResult else { return nil }
        guard case let .song(cardSong) = card.item,
              let first = self.collapsingVariants(response.allItems).first,
              case let .song(song) = first,
              SongVariantMatcher.normalizedTitle(song.title) == SongVariantMatcher.normalizedTitle(cardSong.title)
        else { return card }

        return card.replacingItem(with: .song(song))
    }

    /// Collapses a song and its music video into the album version, at the pair's first position.
    ///
    /// A row replaces the other only when one side is a video variant: two audio rows with the same
    /// title can be different recordings (a studio take and a remix), so they are both kept.
    static func audioPreferred(_ songs: [Song]) -> [Song] {
        self.collapsingVariants(songs.map { SearchResultItem.song($0) }).compactMap { item in
            if case let .song(song) = item { return song }
            return nil
        }
    }

    private static func collapsingVariants(_ items: [SearchResultItem]) -> [SearchResultItem] {
        var result: [SearchResultItem] = []
        var firstIndexByTitle: [String: Int] = [:]

        for item in items {
            guard case let .song(song) = item else {
                result.append(item)
                continue
            }

            let title = SongVariantMatcher.normalizedTitle(song.title)
            guard !title.isEmpty, let index = firstIndexByTitle[title], case let .song(existing) = result[index] else {
                if !title.isEmpty {
                    firstIndexByTitle[title] = result.count
                }
                result.append(item)
                continue
            }

            guard Self.sameRecording(existing, song) else {
                result.append(item)
                continue
            }

            if existing.isVideoVariant || existing.artists.isEmpty {
                if !song.isVideoVariant || existing.artists.isEmpty {
                    // The album version takes the video's row, so the list leads with the song. A card
                    // row carries no artist names, so a same-titled row that names them supersedes it
                    // even when the card reported no video type.
                    result[index] = item
                } else {
                    // Another video upload of the same track: not the pair we are looking for.
                    result.append(item)
                }
            } else if !song.isVideoVariant {
                result.append(item)
            }
            // A video under an album version is the pair's other half: already covered, drop it.
        }

        return result
    }

    /// Whether two rows name the same recording: same title, and artists that do not contradict.
    ///
    /// The "Top result" card carries no artist names, so a row without artists matches the shelf
    /// row that names them.
    private static func sameRecording(_ lhs: Song, _ rhs: Song) -> Bool {
        let lhsArtists = Self.artistNames(of: lhs)
        let rhsArtists = Self.artistNames(of: rhs)
        guard !lhsArtists.isEmpty, !rhsArtists.isEmpty else { return true }
        return !lhsArtists.isDisjoint(with: rhsArtists)
    }

    private static func artistNames(of song: Song) -> Set<String> {
        Set(song.artists.map { SongVariantMatcher.normalizedArtist($0.name) }.filter { !$0.isEmpty })
    }
}
