import Foundation
import Testing
@testable import Kaset

/// Which pages the header's library action may be offered on.
///
/// The action writes `like/like` with an ID as a `playlistId` (`YTMusicClient.subscribeToPlaylist`), so it only
/// means something for a page the library can hold, and only if it is sent the ID the library holds it under.
/// Two pages are not holdable at all — a mix or radio (`RD…`: `RDCLAK…`, `RDEM…`, `RDTMAK…`, `RDAMVM…`),
/// which nothing stores, and Liked Music (`LM`), which *is* the library's list of liked songs — and an album
/// is holdable only through its `OLAK5uy_…` audio playlist: its `MPREb_…` page ID is a page the library can
/// never list back, so a page saved by that ID read "Add to Library" whether or not the album was saved and
/// changed nothing when it was clicked.
///
/// `PlaylistDetailView.offersLibraryAction(for:)` is the other half of the rule — a page the library
/// already holds keeps the action, so it can be removed — and its source is guarded in
/// `HeaderActionRowTests` because the view itself is private.
@Suite("Playlist library action")
struct PlaylistLibraryActionTests {
    /// `MainWindow`'s source, from the test file's own location.
    private static let mainWindowSource: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // the file
        .deletingLastPathComponent() // KasetTests
        .deletingLastPathComponent() // Tests
        .appending(path: "Sources/Kaset/Views/MainWindow.swift")

    /// Membership is read off the window's library through the environment, so a pane that does not state
    /// the injection hands the page `nil` — and a page with no library reports every item as not in it. A
    /// playlist opened straight from the sidebar was exactly that: its branch built the page outside the
    /// injection the navigation branches made, so the control read "Add to Library" on the reader's own
    /// playlists, in a window whose sidebar listed them.
    @Test("Every page in the content pane can read the window's library")
    func contentPaneInjectsTheLibrary() throws {
        let source = try String(contentsOf: Self.mainWindowSource, encoding: .utf8)
        let detailView = try #require(
            source.range(of: "private func detailView(for selection:"),
            "The window no longer has a content pane to inject the library into."
        )
        let sidebarBranch = try #require(
            source.range(of: "private func viewForSidebarSelection("),
            "The window no longer builds pages from a sidebar selection."
        )
        #expect(
            source[detailView.lowerBound ..< sidebarBranch.lowerBound]
                .contains(".environment(self.libraryViewModel)"),
            """
            The content pane no longer injects the window's library, so a page shown by a branch that never \
            stated it — the sidebar's own playlist branch is the one this was found by — reads `nil` and \
            answers "not in the library" about everything the account owns.
            """
        )
    }

    private func detail(_ id: String) -> PlaylistDetail {
        TestFixtures.makePlaylistDetail(playlist: TestFixtures.makePlaylist(id: id), trackCount: 3)
    }

    /// Whether a search result's context menu, or any other surface holding the item itself, offers the
    /// action. It is the same taxonomy as the detail page's, stated once in `Playlist.isLibraryHoldable(id:)`.
    private func playlist(_ id: String) -> Playlist {
        TestFixtures.makePlaylist(id: id)
    }

    @Test(
        "A page whose ID is not a playlist the library can hold is not offered the action",
        arguments: [
            "MPREb_dai-dai", // album page: a browse ID, not the audio playlist the library stores
            "VLMPREb_dai-dai",
            "LM", // Liked Music: the library's own list
            "VLLM",
            "RDCLAK5uy_curated-mix", // radio playlists are generated, not stored
            "RDEM1-qMCYe8pGt51RoZyWxAYg",
            "RDTMAK5uy_mixtape",
            "RDAMVMdQw4w9WgXcQ",
        ]
    )
    func unholdablePagesHaveNoLibraryAction(id: String) {
        let detail = self.detail(id)
        #expect(
            !detail.supportsLibraryMembership,
            """
            \(id) is offered the library action. It cannot be added to the library (the write sends the page's \
            ID as a `playlistId`) and it can never be read back from it either, so the control can only repeat \
            "Add to Library" whatever the reader does with it.
            """
        )
        #expect(
            !self.playlist(id).supportsLibraryMembership,
            """
            The playlist itself says the library can hold it, so any surface that holds the item rather than a \
            detail page for it — the search results' context menu — offers an action that does nothing.
            """
        )
        #expect(!Playlist.isLibraryHoldable(id: id), "The static and the two properties have to agree.")
    }

    @Test(
        "A playlist and an album's audio playlist are what the library holds",
        arguments: [
            "PLxyz123",
            "VLPLxyz123",
            "OLAK5uy_kJIcTYhPGkiDOlYfL3W8Q20RarHQC2d2I", // an album addressed by its audio playlist
            "VLOLAK5uy_kJIcTYhPGkiDOlYfL3W8Q20RarHQC2d2I",
        ]
    )
    func holdablePagesKeepTheLibraryAction(id: String) {
        #expect(
            self.detail(id).supportsLibraryMembership,
            """
            \(id) is a playlist ID the library endpoint accepts, and it is the only way the page's membership \
            can be added or removed at all.
            """
        )
        #expect(self.playlist(id).supportsLibraryMembership)
    }

    /// An album page is `MPREb_…`, a page ID the library cannot store — but the album's own radio target
    /// names the `OLAK5uy_…` audio playlist the library *does* store it under, which is what an album page is
    /// saved by.
    @Test("An album uses the audio playlist its radio target names")
    func albumPagesSaveUnderTheirAudioPlaylist() {
        let album = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "MPREb_dai-dai"),
            trackCount: 3
        )
        let withRadio = PlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "MPREb_dai-dai"),
            tracks: album.tracks,
            mixPlaylistId: "RDAMPLOLAK5uy_n-8F30tR88wyIupcq9ug5zY-JWMX54nHM"
        )

        #expect(withRadio.libraryId == "OLAK5uy_n-8F30tR88wyIupcq9ug5zY-JWMX54nHM")
        #expect(withRadio.supportsLibraryMembership)
        #expect(
            album.libraryId == nil && !album.supportsLibraryMembership,
            """
            An album page whose header named no radio target has no audio playlist to save under, so it must \
            not offer a control that would send its page ID as a playlist ID.
            """
        )
    }

    /// A playlist's radio target is `RDAMPL` + the playlist's own ID, which is not an album's audio playlist —
    /// deriving from any `RDAMPL` target would save the wrong item.
    @Test("A playlist keeps its own ID whatever its radio target names")
    func playlistsDoNotDeriveFromTheirRadio() {
        let playlist = PlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VLPLowned123"),
            tracks: [],
            mixPlaylistId: "RDAMPLPLowned123"
        )

        #expect(playlist.libraryId == "PLowned123")
    }

    @Test("A mix, Liked Music and an unknown ID shape have no library ID")
    func unholdablePagesHaveNoLibraryID() {
        for id in ["RDCLAK5uy_x", "RDEM123", "LM", "VLLM", "something-else"] {
            #expect(self.detail(id).libraryId == nil, "\(id) should have no library ID to write to.")
        }
    }

    /// The page's own save action is the target YouTube Music itself writes, and it is trusted over
    /// anything derived here — it is where an album page finds the `OLAK5uy_…` audio playlist the library
    /// stores it under, and it is never the `MPREb_…` page the album is browsed by.
    @Test("The page's own save target is what a library write uses")
    func headerSaveTargetIsPreferred() {
        let album = PlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "MPREb_dai-dai"),
            tracks: [],
            libraryPlaylistId: "OLAK5uy_fromTheHeader"
        )
        #expect(album.libraryId == "OLAK5uy_fromTheHeader")

        let playlist = PlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VLPLowned123"),
            tracks: [],
            libraryPlaylistId: "PLowned123"
        )
        #expect(playlist.libraryId == "PLowned123")

        // A target that is a page, a radio or a `VL` alias is not one: the header's own target has to be
        // a playlist the write accepts, or the derivation has to stand in.
        let pageTarget = PlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "MPREb_dai-dai"),
            tracks: [],
            mixPlaylistId: "RDAMPLOLAK5uy_fromTheRadio",
            libraryPlaylistId: "MPREb_dai-dai"
        )
        #expect(pageTarget.libraryId == "OLAK5uy_fromTheRadio")
    }

    /// Membership is read back by every ID the page can be known by: the library lists a saved album by its
    /// page (`MPREb_…`) while the page is saved under its `OLAK5uy_…` audio playlist, so asking by one
    /// spelling alone reports an album the account already owns as unsaved — which is how "Add to Library"
    /// turned a saved album into a repeat offer, and how an add looked like it undid itself afterwards.
    @Test("A page matches its library entry through either ID it can be known by")
    func matchIdsCoverBothSpellings() {
        let album = PlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "MPREb_dai-dai"),
            tracks: [],
            mixPlaylistId: "RDAMPLOLAK5uy_audioPlaylist"
        )
        #expect(
            album.libraryMatchIds == ["MPREb_dai-dai", "OLAK5uy_audioPlaylist"],
            """
            The album page matches only one of the two IDs the library may list it under, so a saved album can \
            still read as unsaved.
            """
        )

        let openedByPlaylist = PlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VLOLAK5uy_audioPlaylist"),
            tracks: []
        )
        #expect(openedByPlaylist.libraryMatchIds == ["VLOLAK5uy_audioPlaylist", "OLAK5uy_audioPlaylist"])
    }

    /// A library entry answers the same question, however the entry was listed.
    @Test("A library entry matches the page it was opened from")
    func playlistsMatchTheirNormalizedId() {
        #expect(TestFixtures.makePlaylist(id: "VLPLxyz123").libraryMatchIds == ["VLPLxyz123", "PLxyz123"])
        #expect(TestFixtures.makePlaylist(id: "MPREb_dai-dai").libraryMatchIds == ["MPREb_dai-dai"])
        #expect(Playlist.isAlbumPageId("MPREb_dai-dai"))
        #expect(Playlist.isAlbumPageId("VLMPREb_dai-dai"))
        #expect(!Playlist.isAlbumPageId("OLAK5uy_audioPlaylist"))
    }

    /// Liked Music is named in both spellings, and its ID is what the sidebar and the library listing use.
    @Test("Liked Music is recognised through its VL alias")
    func likedMusicIsNormalised() {
        #expect(self.detail("VLLM").isLikedMusic)
        #expect(self.detail("LM").isLikedMusic)
        #expect(!self.detail("VLPLxyz123").isLikedMusic)
        #expect(self.detail("VLLM").normalizedId == "LM")
        #expect(self.detail("VLPLxyz123").normalizedId == "PLxyz123")
    }

    /// The two properties the rule is made of have to agree: every page the view draws for Liked Music is
    /// also a page the library action is never offered on.
    @Test("Liked Music is never a library membership, saved or not")
    func likedMusicHasNoMembership() {
        for id in ["LM", "VLLM"] {
            let detail = self.detail(id)
            #expect(detail.isLikedMusic && !detail.supportsLibraryMembership)
        }
    }
}
