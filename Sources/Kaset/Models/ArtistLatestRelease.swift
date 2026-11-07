import Foundation

// MARK: - ArtistLatestRelease

/// The release an artist page promotes at the top: the artist's newest album or single, while it is
/// still new.
struct ArtistLatestRelease: Identifiable, Equatable {
    enum Kind: Equatable {
        case album
        case single
    }

    let album: Album
    let kind: Kind

    var id: String {
        self.album.id
    }
}

extension ArtistDetail {
    /// The artist's newest album or single, but only while it is a *new* release.
    ///
    /// The artist page's shelves arrive newest first and carry only the release year, so the newest
    /// matching item is the first one from the current calendar year: in January the card is already
    /// gone for last year's album rather than staying up all year on a stale date.
    func latestRelease(currentYear: Int = Calendar.current.component(.year, from: Date())) -> ArtistLatestRelease? {
        let albums = self.albums.map { ArtistLatestRelease(album: $0, kind: .album) }
        let singles = self.singles.map { ArtistLatestRelease(album: $0, kind: .single) }
        // Albums come first so a same-year single never displaces the album it belongs to.
        return (albums + singles).first { $0.album.releaseYear == currentYear }
    }
}

extension Album {
    /// The release year as a number. The shelf card's year text is the `Album.year` string.
    var releaseYear: Int? {
        guard let year = self.year else { return nil }
        let digits = year.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}
