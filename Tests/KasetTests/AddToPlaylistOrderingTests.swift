import Foundation
import Testing
@testable import Kaset

/// The order the Add-to-Playlist popover offers playlists in.
///
/// `playlist/get_add_to_playlist` answers alphabetically, so nothing on that response states the order
/// the reader knows: the library's. The sheet re-orders against the library and puts the playlists that
/// already hold the song first, which is what makes a checked row something the reader can see.
@Suite("Add to playlist ordering")
struct AddToPlaylistOrderingTests {
    private func entry(_ id: String) -> AddToPlaylistEntry {
        AddToPlaylistEntry(
            id: id,
            title: id,
            subtitle: "10 songs",
            thumbnailURL: nil,
            canAddVideo: true,
            canRemoveVideoById: true,
            containsVideo: false
        )
    }

    private func ids(_ entries: [AddToPlaylistEntry]) -> [String] {
        entries.map(\.id)
    }

    @Test("The library's order wins over the API's alphabetical order")
    func libraryOrderWins() {
        let entries = [self.entry("PLapple"), self.entry("PLbanana"), self.entry("PLcherry")]

        let arranged = AddToPlaylistOrdering.arranged(
            entries,
            libraryOrder: ["VLPLcherry", "VLPLbanana", "VLPLapple"],
            containsVideo: { _ in false }
        )

        #expect(self.ids(arranged) == ["PLcherry", "PLbanana", "PLapple"])
    }

    @Test("Playlists already holding the song come first, still in library order")
    func membersComeFirst() {
        let entries = [self.entry("PLa"), self.entry("PLb"), self.entry("PLc"), self.entry("PLd")]
        let members: Set<String> = ["PLc", "PLd"]

        let arranged = AddToPlaylistOrdering.arranged(
            entries,
            libraryOrder: ["PLa", "PLb", "PLc", "PLd"],
            containsVideo: { members.contains($0.id) }
        )

        #expect(self.ids(arranged) == ["PLc", "PLd", "PLa", "PLb"])
    }

    @Test("A playlist the library does not list keeps its place after the ranked ones")
    func unrankedEntriesKeepTheirOrder() {
        let entries = [self.entry("PLd"), self.entry("PLb"), self.entry("PLa"), self.entry("PLc")]

        let arranged = AddToPlaylistOrdering.arranged(
            entries,
            libraryOrder: ["PLa", "PLc"],
            containsVideo: { _ in false }
        )

        #expect(self.ids(arranged) == ["PLa", "PLc", "PLd", "PLb"])
    }

    @Test("Podcast episode playlists are not offered and take no rank")
    func podcastAutoPlaylistsAreDropped() {
        let entries = [self.entry("RDPN"), self.entry("PLa"), self.entry("SE")]

        let arranged = AddToPlaylistOrdering.arranged(
            entries,
            libraryOrder: ["VLRDPN", "VLSE", "VLPLa"],
            containsVideo: { _ in false }
        )

        #expect(self.ids(arranged) == ["PLa"])
    }

    @Test("A library entry and an add target match through the VL alias")
    func libraryAliasMatchesTheEntry() {
        let entries = [self.entry("VLPLb"), self.entry("PLa")]

        let arranged = AddToPlaylistOrdering.arranged(
            entries,
            libraryOrder: ["VLPLa", "VLPLb"],
            containsVideo: { _ in false }
        )

        #expect(self.ids(arranged) == ["PLa", "VLPLb"])
    }
}
