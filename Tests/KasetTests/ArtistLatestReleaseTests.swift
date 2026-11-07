import Foundation
import Testing
@testable import Kaset

/// Tests for the artist page's latest-release lookup.
@Suite("ArtistLatestRelease", .tags(.model))
struct ArtistLatestReleaseTests {
    private let artist = Artist(id: "UC-test", name: "Test Artist")

    private func makeDetail(albums: [Album] = [], singles: [Album] = []) -> ArtistDetail {
        ArtistDetail(
            artist: self.artist,
            description: nil,
            songs: [],
            albums: albums,
            singles: singles,
            thumbnailURL: nil
        )
    }

    private func makeAlbum(_ id: String, _ title: String, year: String?) -> Album {
        Album(id: id, title: title, artists: nil, thumbnailURL: nil, year: year, trackCount: nil)
    }

    @Test("Picks the newest album of the current year")
    func picksNewestAlbumOfCurrentYear() {
        let detail = self.makeDetail(albums: [
            self.makeAlbum("MPRE-old", "Old Album", year: "2023"),
            self.makeAlbum("MPRE-new", "New Album", year: "2026"),
        ])

        let release = detail.latestRelease(currentYear: 2026)

        #expect(release?.album.id == "MPRE-new")
        #expect(release?.kind == .album)
    }

    @Test("Falls back to a single when no album is from the current year")
    func fallsBackToCurrentYearSingle() {
        let detail = self.makeDetail(
            albums: [self.makeAlbum("MPRE-old", "Old Album", year: "2024")],
            singles: [self.makeAlbum("MPRE-single", "New Single", year: "2026")]
        )

        let release = detail.latestRelease(currentYear: 2026)

        #expect(release?.album.id == "MPRE-single")
        #expect(release?.kind == .single)
    }

    @Test("Prefers the album over a same-year single")
    func prefersAlbumOverSameYearSingle() {
        let detail = self.makeDetail(
            albums: [self.makeAlbum("MPRE-album", "Album", year: "2026")],
            singles: [self.makeAlbum("MPRE-single", "Single", year: "2026")]
        )

        #expect(detail.latestRelease(currentYear: 2026)?.kind == .album)
    }

    @Test("No card when nothing came out this year")
    func noReleaseOutsideCurrentYear() {
        let detail = self.makeDetail(
            albums: [self.makeAlbum("MPRE-old", "Old Album", year: "2025")],
            singles: [self.makeAlbum("MPRE-unknown", "Undated", year: nil)]
        )

        #expect(detail.latestRelease(currentYear: 2026) == nil)
    }

    @Test("Release year reads the leading year digits")
    func releaseYearReadsLeadingDigits() {
        #expect(self.makeAlbum("MPRE-1", "A", year: "2026").releaseYear == 2026)
        #expect(self.makeAlbum("MPRE-2", "B", year: nil).releaseYear == nil)
        #expect(self.makeAlbum("MPRE-3", "C", year: "Unknown").releaseYear == nil)
    }
}
