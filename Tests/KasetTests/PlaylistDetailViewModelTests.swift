import Foundation
import Testing
@testable import Kaset

/// Tests for PlaylistDetailViewModel using mock client.
@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct PlaylistDetailViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: PlaylistDetailViewModel

    /// Per-suite cache directory. Without it these tests would read and write the real Application
    /// Support cache, where one test's stored page would open in the next.
    private let cacheDirectory: URL

    private var cache: PlaylistDetailCache {
        PlaylistDetailCache(directory: self.cacheDirectory)
    }

    init() {
        self.mockClient = MockYTMusicClient()
        let cache = PlaylistDetailCache(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("KasetPlaylistCacheTests-\(UUID().uuidString)", isDirectory: true)
        )
        self.cacheDirectory = cache.directoryURL
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist", title: "Test Playlist")
        self.viewModel = PlaylistDetailViewModel(playlist: playlist, client: self.mockClient, cache: cache)
        // Page counts below are deterministic only without the background prefill, which has its
        // own tests.
        self.viewModel.prefetchesFollowingPage = false
    }

    /// Waits for `expectation` to hold, or for `timeout` to elapse.
    ///
    /// Background work is fire-and-forget, so there is no handle to await and its completion is only
    /// observable through its effects. Polling a condition until a deadline — rather than sleeping a
    /// fixed interval — keeps these tests from flaking when the whole suite runs in parallel.
    private func waitUntil(
        _ expectation: @autoclosure () -> Bool,
        timeout: Duration = .seconds(3)
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !expectation(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Initial State Tests

    @Test("Initial state is idle with no playlist detail")
    func initialState() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.playlistDetail == nil)
        #expect(self.viewModel.hasMore == false)
    }

    // MARK: - Account Switch Tests

    /// A playlist page holds the account's own list — and the Liked Music page *is* the account's
    /// liked songs — so switching channels has to load the page again instead of leaving the
    /// previous channel's rows, and their like state, on screen.
    @Test("Switching accounts drops the loaded list and loads the new account's")
    func accountSwitchReloads() async {
        self.mockClient.playlistDetails["VL-test-playlist"] = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 2
        )
        await self.viewModel.loadIfAccountChanged("primary")
        #expect(self.mockClient.getPlaylistIds.count == 1)
        #expect(self.viewModel.playlistDetail?.tracks.count == 2)

        self.mockClient.playlistDetails["VL-test-playlist"] = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 5
        )
        await self.viewModel.loadIfAccountChanged("brand-channel")

        #expect(self.mockClient.getPlaylistIds.count == 2)
        #expect(self.viewModel.playlistDetail?.tracks.count == 5)

        // The same account again is a no-op, which is what lets the page key its load on the ID.
        await self.viewModel.loadIfAccountChanged("brand-channel")
        #expect(self.mockClient.getPlaylistIds.count == 2)
    }

    // MARK: - Load Tests

    @Test("Load success sets playlist detail")
    func loadSuccess() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 10
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail

        await self.viewModel.load()

        #expect(self.mockClient.getPlaylistCalled == true)
        #expect(self.mockClient.getPlaylistIds.first == "VL-test-playlist")
        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.playlistDetail != nil)
        #expect(self.viewModel.playlistDetail?.tracks.count == 10)
    }

    @Test("Load error sets error state")
    func loadError() async {
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.viewModel.load()

        #expect(self.mockClient.getPlaylistCalled == true)
        if case let .error(error) = viewModel.loadingState {
            #expect(!error.message.isEmpty)
            #expect(error.isRetryable)
        } else {
            Issue.record("Expected error state")
        }
        #expect(self.viewModel.playlistDetail == nil)
    }

    @Test("Load does not duplicate when already loading")
    func loadDoesNotDuplicateWhenAlreadyLoading() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 5
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail

        await self.viewModel.load()
        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
    }

    // MARK: - Radio

    @Test("The header's radio playlist survives paging")
    func radioPlaylistSurvivesPaging() async {
        self.mockClient.playlistDetails["VL-test-playlist"] = PlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            tracks: TestFixtures.makeSongs(count: 5),
            mixPlaylistId: "RDAMPLPL-radio-source"
        )
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [TestFixtures.makeSong(id: "cont-1")],
        ]

        await self.viewModel.load()
        #expect(self.viewModel.playlistDetail?.mixPlaylistId == "RDAMPLPL-radio-source")

        await self.viewModel.loadMore()

        #expect(self.viewModel.playlistDetail?.tracks.count == 6)
        #expect(self.viewModel.playlistDetail?.mixPlaylistId == "RDAMPLPL-radio-source")
    }

    @Test("The header's radio playlist survives a partial header merge")
    func radioPlaylistSurvivesHeaderMerge() async {
        // A header the parser could not fully read is merged with the playlist the navigation carried,
        // which rebuilds the detail — the radio has to be carried across with it.
        let sparsePlaylist = Playlist(
            id: "VL-test-playlist",
            title: "Unknown Playlist",
            description: nil,
            thumbnailURL: nil,
            trackCount: nil,
            author: nil
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = PlaylistDetail(
            playlist: sparsePlaylist,
            tracks: TestFixtures.makeSongs(count: 3),
            mixPlaylistId: "RDAMPLPL-radio-source"
        )

        await self.viewModel.load()

        #expect(self.viewModel.playlistDetail?.title == "Test Playlist")
        #expect(self.viewModel.playlistDetail?.mixPlaylistId == "RDAMPLPL-radio-source")
    }

    // MARK: - Load More Tests

    @Test("Load more appends tracks")
    func loadMoreAppendsTracks() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 5
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [
                TestFixtures.makeSong(id: "cont-1"),
                TestFixtures.makeSong(id: "cont-2"),
            ],
        ]

        await self.viewModel.load()
        #expect(self.viewModel.playlistDetail?.tracks.count == 5)
        #expect(self.viewModel.hasMore == true)

        await self.viewModel.loadMore()

        #expect(self.mockClient.getPlaylistContinuationCalled == true)
        #expect(self.viewModel.playlistDetail?.tracks.count == 7)
    }

    @Test("Load more preserves reported total track count")
    func loadMorePreservesReportedTotalTrackCount() async {
        let playlist = Playlist(
            id: "VL-test-playlist",
            title: "Large Playlist",
            description: "A test playlist",
            thumbnailURL: URL(string: "https://example.com/playlist.jpg"),
            trackCount: 2429,
            author: "Test User"
        )
        let playlistDetail = PlaylistDetail(
            playlist: playlist,
            tracks: TestFixtures.makeSongs(count: 100),
            duration: "135+ hours"
        )
        let continuationTracks = (100 ..< 150).map { index in
            TestFixtures.makeSong(id: "video-\(index)", title: "Song \(index)")
        }

        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [continuationTracks]

        await self.viewModel.load()
        await self.viewModel.loadMore()

        #expect(self.viewModel.playlistDetail?.tracks.count == 150)
        #expect(self.viewModel.playlistDetail?.trackCount == 2429)
    }

    @Test("Load more deduplicates tracks")
    func loadMoreDeduplicatesTracks() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 3
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [
                TestFixtures.makeSong(id: "video-0"), // Duplicate
                TestFixtures.makeSong(id: "new-track"),
            ],
        ]

        await self.viewModel.load()
        await self.viewModel.loadMore()

        #expect(self.viewModel.playlistDetail?.tracks.count == 4) // 3 original + 1 new
    }

    @Test("Load more stops on all duplicates")
    func loadMoreStopsOnAllDuplicates() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 2
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [
                TestFixtures.makeSong(id: "video-0"),
                TestFixtures.makeSong(id: "video-1"),
            ],
        ]

        await self.viewModel.load()
        await self.viewModel.loadMore()

        #expect(self.viewModel.playlistDetail?.tracks.count == 2)
        #expect(self.viewModel.hasMore == false)
    }

    @Test("Load more does nothing when not loaded")
    func loadMoreDoesNothingWhenNotLoaded() async {
        #expect(self.viewModel.loadingState == .idle)

        await self.viewModel.loadMore()

        #expect(self.mockClient.getPlaylistContinuationCalled == false)
    }

    @Test("Load more does nothing when no more tracks")
    func loadMoreDoesNothingWhenNoMore() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 3
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail
        // No continuation tracks set

        await self.viewModel.load()
        #expect(self.viewModel.hasMore == false)

        await self.viewModel.loadMore()

        #expect(self.mockClient.getPlaylistContinuationCalled == false)
    }

    // MARK: - Background Prefill Tests

    @Test("Load prefetches the following page")
    func loadPrefetchesFollowingPage() async {
        self.viewModel.prefetchesFollowingPage = true
        self.mockClient.playlistDetails["VL-test-playlist"] = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 5
        )
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [
                TestFixtures.makeSong(id: "cont-1"),
                TestFixtures.makeSong(id: "cont-2"),
            ],
        ]

        await self.viewModel.load()
        await        self.waitUntil( self.viewModel.playlistDetail?.tracks.count == 7)

        #expect(self.mockClient.getPlaylistContinuationCallCount == 1)
        #expect(self.viewModel.playlistDetail?.tracks.count == 7)
        #expect(self.viewModel.loadingState == .loaded)
    }

    @Test("Preload keeps a single page of headroom")
    func preloadKeepsSinglePageOfHeadroom() async {
        self.viewModel.prefetchesFollowingPage = true
        self.mockClient.playlistDetails["VL-test-playlist"] = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 3
        )
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [TestFixtures.makeSong(id: "page-2-a"), TestFixtures.makeSong(id: "page-2-b")],
            [TestFixtures.makeSong(id: "page-3-a")],
        ]

        await self.viewModel.load()
        await        self.waitUntil( self.viewModel.playlistDetail?.tracks.count == 5)

        // Only one page beyond the first is fetched, and the rest is left to scroll-driven paging.
        #expect(self.mockClient.getPlaylistContinuationCallCount == 1)
        #expect(self.viewModel.playlistDetail?.tracks.count == 5)
        #expect(self.viewModel.hasMore == true)
    }

    @Test("Overlapping page loads issue a single continuation request")
    func overlappingPageLoadsCoalesce() async {
        self.viewModel.prefetchesFollowingPage = true
        self.mockClient.playlistDetails["VL-test-playlist"] = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 3
        )
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [TestFixtures.makeSong(id: "page-2-a")],
            [TestFixtures.makeSong(id: "page-3-a")],
        ]
        self.mockClient.playlistContinuationDelay = .milliseconds(50)

        await self.viewModel.load()

        // The prefill is still in flight, so both scroll-triggered loads join it instead of
        // starting their own continuation request.
        async let first: Void = self.viewModel.loadMore()
        async let second: Void = self.viewModel.loadMore()
        _ = await (first, second)

        #expect(self.mockClient.getPlaylistContinuationCallCount == 1)
        #expect(self.viewModel.playlistDetail?.tracks.count == 4)

        // Once the shared page settles, the next page still loads on demand.
        await self.viewModel.loadMore()

        #expect(self.mockClient.getPlaylistContinuationCallCount == 2)
        #expect(self.viewModel.playlistDetail?.tracks.count == 5)
    }

    @Test("Dedupe set persists across pages")
    func dedupeSetPersistsAcrossPages() async {
        self.mockClient.playlistDetails["VL-test-playlist"] = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 2
        )
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [TestFixtures.makeSong(id: "page-2-a"), TestFixtures.makeSong(id: "video-0")],
            [TestFixtures.makeSong(id: "page-2-a"), TestFixtures.makeSong(id: "page-3-a")],
        ]

        await self.viewModel.load()
        await self.viewModel.loadMore()
        await self.viewModel.loadMore()

        // video-0 is a first-page duplicate, page-2-a is a duplicate of the previous page.
        #expect(self.viewModel.playlistDetail?.tracks.count == 4)
    }

    @Test("Refresh drops a stale in-flight page and rebuilds the dedupe set")
    func refreshDropsStalePageAndRebuildsDedupeSet() async {
        self.viewModel.prefetchesFollowingPage = true
        self.mockClient.playlistDetails["VL-test-playlist"] = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 3
        )
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [TestFixtures.makeSong(id: "page-2-a")],
        ]
        self.mockClient.playlistContinuationDelay = .milliseconds(300)

        await self.viewModel.load()
        // Wait only until the request has been issued: the page is deliberately still in flight, so
        // there is nothing to wait for beyond that.
        await        self.waitUntil( self.mockClient.getPlaylistContinuationCallCount == 1)

        // The prefetched page is still in flight, so it has not landed yet.
        #expect(self.viewModel.playlistDetail?.tracks.count == 3)
        #expect(self.viewModel.hasMore == true)

        // Refresh replaces the track list, so the stale page is dropped and the refreshed
        // detail prefetches again.
        self.mockClient.playlistContinuationDelay = nil
        await self.viewModel.refresh()
        await        self.waitUntil( self.viewModel.playlistDetail?.tracks.count == 4)

        #expect(self.viewModel.playlistDetail?.tracks.count == 4)
        #expect(self.viewModel.playlistDetail?.tracks.last?.videoId == "page-2-a")
    }

    // MARK: - Refresh Tests

    @Test("Refresh updates detail without clearing")
    func refreshUpdatesDetailWithoutClearing() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 5
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail

        await self.viewModel.load()
        #expect(self.viewModel.playlistDetail?.tracks.count == 5)

        // Update mock to return different track count
        let newPlaylistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 8
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = newPlaylistDetail

        await self.viewModel.refresh()

        #expect(self.viewModel.playlistDetail?.tracks.count == 8)
        #expect(self.viewModel.loadingState == .loaded)
    }

    @Test("Refresh keeps existing detail on error")
    func refreshKeepsDetailOnError() async {
        let playlistDetail = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 5
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail

        await self.viewModel.load()
        #expect(self.viewModel.playlistDetail?.tracks.count == 5)

        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.viewModel.refresh()

        #expect(self.viewModel.playlistDetail?.tracks.count == 5)
        #expect(self.viewModel.loadingState == .loaded)
    }

    // MARK: - Fallback Tests

    @Test("Load uses original playlist info for unknown title")
    func loadUsesOriginalPlaylistInfoForUnknownTitle() async {
        // Create a playlist detail with "Unknown Playlist" title
        let unknownPlaylist = Playlist(
            id: "VL-test-playlist",
            title: "Unknown Playlist",
            description: nil,
            thumbnailURL: nil,
            trackCount: 3,
            author: nil
        )
        let playlistDetail = PlaylistDetail(
            playlist: unknownPlaylist,
            tracks: TestFixtures.makeSongs(count: 3),
            duration: "10 min"
        )
        self.mockClient.playlistDetails["VL-test-playlist"] = playlistDetail

        await self.viewModel.load()

        // Should use original playlist title "Test Playlist" instead of "Unknown Playlist"
        #expect(self.viewModel.playlistDetail?.title == "Test Playlist")
    }

    // MARK: - Artist Tests

    @Test("Album tracks without bylines inherit the album's artists")
    func albumTracksInheritAlbumArtists() async {
        let artists = [
            Artist(id: "UC-shakira", name: "Shakira"),
            Artist(id: "UC-burna", name: "Burna Boy"),
        ]
        let album = Playlist(
            id: "MPREb-dai-dai",
            title: "Dai Dai",
            description: nil,
            thumbnailURL: URL(string: "https://example.com/album.jpg"),
            trackCount: 2,
            author: "Shakira, Burna Boy"
        )
        // Album pages list their tracks without a byline column, so these arrive artist-less.
        let tracks = ["video-1", "video-2"].map { id in
            Song(
                id: id,
                title: "Track \(id)",
                artists: [],
                duration: 200,
                videoId: id
            )
        }
        self.mockClient.playlistDetails["MPREb-dai-dai"] = PlaylistDetail(
            playlist: album,
            tracks: tracks,
            duration: "7 minutes",
            artists: artists
        )

        let viewModel = PlaylistDetailViewModel(playlist: album, client: self.mockClient, cache: self.cache)
        viewModel.prefetchesFollowingPage = false
        await viewModel.load()

        let detail = viewModel.playlistDetail
        #expect(detail?.artists.map(\.name) == ["Shakira", "Burna Boy"])
        #expect(detail?.tracks.allSatisfy { $0.artists.map(\.id) == ["UC-shakira", "UC-burna"] } == true)
        #expect(detail?.tracks.allSatisfy { $0.album?.id == "MPREb-dai-dai" } == true)
    }

    @Test("Playlist creator is not stamped onto every track")
    func playlistCreatorIsNotStampedOntoTracks() async {
        let playlist = Playlist(
            id: "VL-test-playlist",
            title: "Test Playlist",
            description: nil,
            thumbnailURL: nil,
            trackCount: 1,
            author: "Rock Bands"
        )
        let creator = Artist(id: "UC-rock-bands", name: "Rock Bands")
        self.mockClient.playlistDetails["VL-test-playlist"] = PlaylistDetail(
            playlist: playlist,
            tracks: [
                Song(
                    id: "video-1",
                    title: "Track 1",
                    artists: [],
                    duration: 200,
                    videoId: "video-1"
                ),
            ],
            artists: [creator]
        )

        await self.viewModel.load()

        #expect(self.viewModel.playlistDetail?.artists == [creator])
        #expect(self.viewModel.playlistDetail?.tracks.first?.artists.isEmpty == true)
    }

    // MARK: - Full-Playlist Search Scan Tests

    @Test("Search scan loads every remaining page")
    func searchScanLoadsEveryRemainingPage() async {
        self.mockClient.playlistDetails["VL-test-playlist"] = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 5
        )
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [TestFixtures.makeSong(id: "page-2-a"), TestFixtures.makeSong(id: "page-2-b")],
            [TestFixtures.makeSong(id: "page-3-a")],
        ]

        await self.viewModel.load()
        #expect(self.viewModel.hasMore == true)
        #expect(self.viewModel.playlistDetail?.tracks.count == 5)

        await self.viewModel.loadAllTracksForSearch()

        #expect(self.viewModel.playlistDetail?.tracks.count == 8)
        #expect(self.viewModel.hasMore == false)
        #expect(self.viewModel.isLoadingAllTracks == false)
        #expect(self.mockClient.getPlaylistContinuationCallCount == 2)
    }

    @Test("Search scan is a no-op when every page is already loaded")
    func searchScanNoOpWhenFullyLoaded() async {
        self.mockClient.playlistDetails["VL-test-playlist"] = TestFixtures.makePlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            trackCount: 3
        )

        await self.viewModel.load()
        await self.viewModel.loadAllTracksForSearch()

        #expect(self.mockClient.getPlaylistContinuationCalled == false)
    }

    // MARK: - Sort Order Tests

    @Test("Changing sort order writes it to the server and reloads")
    func changeSortOrderWritesToServer() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist")
        self.mockClient.playlistDetails["VL-test-playlist"] = PlaylistDetail(
            playlist: playlist,
            tracks: TestFixtures.makeSongs(count: 3),
            sortOrder: .manual,
            availableSortOrders: PlaylistSortOrder.standard,
            isEditable: true
        )

        await self.viewModel.load()
        #expect(self.viewModel.playlistDetail?.sortOrder == .manual)

        await self.viewModel.changeSortOrder(to: .newestFirst)

        #expect(self.mockClient.setPlaylistSortOrderCalled == true)
        #expect(self.mockClient.setPlaylistSortOrderPlaylistIds == ["VL-test-playlist"])
        #expect(self.mockClient.setPlaylistSortOrders == [.newestFirst])
        #expect(self.viewModel.playlistDetail?.sortOrder == .newestFirst)
        #expect(self.viewModel.isChangingSortOrder == false)
        #expect(self.viewModel.sortOrderError == nil)
    }

    @Test("Changing sort order surfaces a server error")
    func changeSortOrderSurfacesError() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist")
        self.mockClient.playlistDetails["VL-test-playlist"] = PlaylistDetail(
            playlist: playlist,
            tracks: TestFixtures.makeSongs(count: 1),
            sortOrder: .manual,
            availableSortOrders: PlaylistSortOrder.standard,
            isEditable: true
        )

        await self.viewModel.load()

        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))
        await self.viewModel.changeSortOrder(to: .newestFirst)

        #expect(self.viewModel.sortOrderError != nil)
        #expect(self.viewModel.playlistDetail?.sortOrder == .manual)
    }

    @Test("A write YouTube Music accepts but does not apply is reported")
    func changeSortOrderReportsAnOrderTheServerKept() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist")
        self.mockClient.playlistDetails["VL-test-playlist"] = PlaylistDetail(
            playlist: playlist,
            tracks: TestFixtures.makeSongs(count: 3),
            sortOrder: .manual,
            availableSortOrders: PlaylistSortOrder.standard,
            isEditable: true
        )

        await self.viewModel.load()

        // YouTube Music can answer STATUS_SUCCEEDED for an order it does not store, and the reloaded
        // playlist then still carries the old order. The list looks unchanged, so the mismatch has to
        // be said out loud instead of being left to look like a slow sort.
        self.mockClient.ignoresPlaylistSortOrders = true
        await self.viewModel.changeSortOrder(to: .newestFirst)

        #expect(self.mockClient.setPlaylistSortOrders == [.newestFirst])
        #expect(self.viewModel.playlistDetail?.sortOrder == .manual)
        #expect(self.viewModel.sortOrderError != nil)
    }

    @Test("An applied write leaves no error behind")
    func changeSortOrderClearsAnEarlierOrderError() async {
        let playlist = TestFixtures.makePlaylist(id: "VL-test-playlist")
        self.mockClient.playlistDetails["VL-test-playlist"] = PlaylistDetail(
            playlist: playlist,
            tracks: TestFixtures.makeSongs(count: 2),
            sortOrder: .manual,
            availableSortOrders: PlaylistSortOrder.standard,
            isEditable: true
        )

        await self.viewModel.load()

        self.mockClient.ignoresPlaylistSortOrders = true
        await self.viewModel.changeSortOrder(to: .newestFirst)
        #expect(self.viewModel.sortOrderError != nil)

        // The next attempt is applied, so the earlier message must not stick around.
        self.mockClient.ignoresPlaylistSortOrders = false
        await self.viewModel.changeSortOrder(to: .newestLast)

        #expect(self.viewModel.playlistDetail?.sortOrder == .newestLast)
        #expect(self.viewModel.sortOrderError == nil)
    }

    // MARK: - Recommendations

    /// The section YouTube Music loads after a playlist's tracks is a set of suggestions, not more
    /// rows of the playlist: appending it to `tracks` numbered them as entries and offered to remove
    /// them from a playlist they were never in.
    @Test("Recommendations that follow the tracks stay out of the playlist")
    func recommendationsStayOutOfTracks() async {
        self.mockClient.playlistDetails["VL-test-playlist"] = PlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            tracks: TestFixtures.makeSongs(count: 3)
        )
        self.mockClient.playlistRecommendationTracks = [[
            TestFixtures.makeSong(id: "rec-1"),
            TestFixtures.makeSong(id: "rec-2"),
        ]]

        await self.viewModel.load()

        #expect(self.mockClient.getPlaylistRecommendationsContinuationCalled)
        #expect(self.viewModel.playlistDetail?.tracks.count == 3)
        #expect(self.viewModel.playlistDetail?.recommendations?.tracks.map(\.videoId) == ["rec-1", "rec-2"])
        #expect(self.viewModel.playlistDetail?.recommendations?.title == "Recommendations")
    }

    /// A page that inlines the shelf needs no second request, and the songs are still kept apart.
    @Test("Inline recommendations are not fetched again")
    func inlineRecommendationsNeedNoRequest() async {
        self.mockClient.playlistDetails["VL-test-playlist"] = PlaylistDetail(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            tracks: TestFixtures.makeSongs(count: 2),
            recommendations: PlaylistRecommendations(
                title: "Recommendations",
                tracks: [TestFixtures.makeSong(id: "rec-inline")]
            )
        )

        await self.viewModel.load()

        #expect(!self.mockClient.getPlaylistRecommendationsContinuationCalled)
        #expect(self.viewModel.playlistDetail?.tracks.count == 2)
        #expect(self.viewModel.playlistDetail?.recommendations?.tracks.map(\.videoId) == ["rec-inline"])
    }

    // MARK: - Stored Page

    /// Stores a page the way an earlier session would have, so the next `load()` finds it.
    private func storePage(trackCount: Int, accountID: String? = nil, artwork: URL? = nil) {
        let playlist = Playlist(
            id: "VL-test-playlist",
            title: "Test Playlist",
            description: "A test playlist",
            thumbnailURL: artwork,
            trackCount: trackCount,
            author: "Test User"
        )
        self.cache.save(
            PlaylistDetail(
                playlist: playlist,
                tracks: TestFixtures.makeSongs(count: trackCount),
                duration: "\(trackCount * 3) minutes"
            ),
            playlistId: "VL-test-playlist",
            accountID: accountID
        )
    }

    /// A playlist opens on the page the previous session stored — rows, header and artwork — and the
    /// fresh answer swaps in behind it, instead of the reader waiting on a spinner.
    @Test("A stored page is on screen while the fresh one is still loading")
    func storedPageShowsBeforeTheNetworkAnswers() async {
        self.storePage(trackCount: 7, artwork: URL(string: "https://example.com/stored.jpg"))
        self.mockClient.playlistDetails["VL-test-playlist"] = TestFixtures.makePlaylistDetail(trackCount: 9)
        self.mockClient.getPlaylistDelay = .milliseconds(300)

        let loading = Task { await self.viewModel.load() }
        await self.waitUntil(self.viewModel.playlistDetail != nil)

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.playlistDetail?.tracks.count == 7)
        #expect(self.viewModel.isRefreshing)

        await loading.value

        #expect(self.viewModel.playlistDetail?.tracks.count == 9)
        #expect(self.viewModel.loadingState == .loaded)
        #expect(!self.viewModel.isRefreshing)
    }

    @Test("A failed refresh keeps the stored page on screen")
    func failedRefreshKeepsStoredPage() async {
        self.storePage(trackCount: 6)
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.playlistDetail?.tracks.count == 6)
        #expect(self.mockClient.getPlaylistCalled)
    }

    /// The header draws from the stored page before the network answers, so the artwork has to be in it.
    @Test("The stored page opens with its artwork")
    func storedPageOpensWithItsArtwork() async {
        let artwork = URL(string: "https://example.com/stored.jpg")
        self.storePage(trackCount: 4, artwork: artwork)
        self.mockClient.getPlaylistDelay = .milliseconds(200)

        let loading = Task { await self.viewModel.load() }
        await self.waitUntil(self.viewModel.playlistDetail?.thumbnailURL != nil)

        #expect(self.viewModel.playlistDetail?.thumbnailURL == artwork)
        await loading.value
    }

    @Test("A stored page with no artwork takes the thumbnail the playlist was opened with")
    func storedPageFallsBackToNavigationArtwork() async {
        self.storePage(trackCount: 3)
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.viewModel.load()

        #expect(self.viewModel.playlistDetail?.thumbnailURL == TestFixtures.makePlaylist().thumbnailURL)
    }

    @Test("A stored page belongs to the account that saved it")
    func storedPageIsScopedToItsAccount() async {
        self.storePage(trackCount: 4, accountID: "primary")
        self.mockClient.playlistDetails["VL-test-playlist"] = TestFixtures.makePlaylistDetail(trackCount: 2)

        await self.viewModel.loadIfAccountChanged("brand-channel")
        #expect(self.viewModel.playlistDetail?.tracks.count == 2)

        // Offline, the account that stored the page still gets it back.
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))
        let primary = PlaylistDetailViewModel(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            client: self.mockClient,
            cache: self.cache
        )
        primary.prefetchesFollowingPage = false
        await primary.loadIfAccountChanged("primary")

        #expect(primary.playlistDetail?.tracks.count == 4)
    }

    @Test("A loaded page is stored for the next open")
    func loadedPageIsStoredForNextOpen() async {
        self.mockClient.playlistDetails["VL-test-playlist"] = TestFixtures.makePlaylistDetail(trackCount: 8)

        await self.viewModel.load()

        #expect(self.cache.load(playlistId: "VL-test-playlist", accountID: nil)?.tracks.count == 8)
    }

    /// The page a reader opened before must be on screen in the very first frame, not one runloop
    /// after it: `.task` runs once the page is already drawn, and until then it shows the loading view.
    @Test("A stored page is on screen at construction")
    func storedPageIsOnScreenAtConstruction() async {
        self.storePage(trackCount: 5, accountID: "primary", artwork: URL(string: "https://example.com/stored.jpg"))

        let page = PlaylistDetailViewModel(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            client: self.mockClient,
            accountID: "primary",
            cache: self.cache
        )

        #expect(page.loadingState == .loaded)
        #expect(page.playlistDetail?.tracks.count == 5)
        #expect(page.playlistDetail?.thumbnailURL == URL(string: "https://example.com/stored.jpg"))
        #expect(!self.mockClient.getPlaylistCalled)
    }

    /// A page seeded under one account must never be read as another account's list.
    @Test("A page seeded for another account is dropped when the account is learned")
    func foreignSeededPageIsDropped() async {
        self.storePage(trackCount: 5, accountID: "primary")
        self.mockClient.playlistDetails["VL-test-playlist"] = TestFixtures.makePlaylistDetail(trackCount: 2)

        let page = PlaylistDetailViewModel(
            playlist: TestFixtures.makePlaylist(id: "VL-test-playlist"),
            client: self.mockClient,
            accountID: "primary",
            cache: self.cache
        )
        #expect(page.playlistDetail?.tracks.count == 5)

        await page.loadIfAccountChanged("brand-channel")

        #expect(page.playlistDetail?.tracks.count == 2)
        #expect(self.mockClient.getPlaylistIds == ["VL-test-playlist"])
    }

    /// Liked Music is `LM` in the sidebar and `VLLM` in a browse response; both are the same page.
    @Test("A stored page is found under either VL spelling")
    func storedPageIsFoundUnderEitherSpelling() {
        self.cache.save(
            TestFixtures.makePlaylistDetail(playlist: TestFixtures.makePlaylist(id: "LM"), trackCount: 2),
            playlistId: "LM",
            accountID: "primary"
        )

        #expect(self.cache.load(playlistId: "VLLM", accountID: "primary")?.tracks.count == 2)
        #expect(self.cache.load(playlistId: "LM", accountID: "primary")?.tracks.count == 2)
    }

    @Test("Paging progress is stored, so a long playlist opens as deep as it was left")
    func pagingProgressIsStored() async {
        self.mockClient.playlistDetails["VL-test-playlist"] = TestFixtures.makePlaylistDetail(trackCount: 3)
        self.mockClient.playlistContinuationTracks["VL-test-playlist"] = [
            [TestFixtures.makeSong(id: "page-2-a")],
        ]

        await self.viewModel.load()
        await self.viewModel.loadMore()

        #expect(self.viewModel.playlistDetail?.tracks.count == 4)
        #expect(self.cache.load(playlistId: "VL-test-playlist", accountID: nil)?.tracks.count == 4)
    }

    @Test("A deleted playlist drops its stored page")
    func forgettingAStoredPage() async {
        self.storePage(trackCount: 3)

        self.viewModel.forgetStoredCopy()

        #expect(self.cache.load(playlistId: "VL-test-playlist", accountID: nil) == nil)
    }
}
