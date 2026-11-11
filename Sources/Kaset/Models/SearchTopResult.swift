import Foundation

// MARK: - SearchTopResult

/// YouTube Music's "Top result": the one item it ranks first, with the subtitle line and the short
/// list of related rows its own page draws beside it.
struct SearchTopResult: Identifiable {
    /// The card's item: the artist page, album, playlist or the track YouTube Music ranks first.
    let item: SearchResultItem

    /// The card's subtitle as YouTube Music words it, e.g. "Artist • 32M monthly audience" or
    /// "Album • Oasis • 1995".
    ///
    /// A song's line is rebuilt from the song itself, so it does not say "Video" for an album version.
    let subtitle: String?

    /// The rows the card lists beside it (YouTube Music draws three).
    let relatedItems: [SearchResultItem]

    var id: String {
        self.item.id
    }

    /// A copy showing `item` in the card's slot, for when the album version stands in for the card's
    /// official music video.
    func replacingItem(with item: SearchResultItem) -> SearchTopResult {
        guard item.id != self.item.id else { return self }
        return SearchTopResult(item: item, subtitle: self.subtitle, relatedItems: self.relatedItems)
    }
}
