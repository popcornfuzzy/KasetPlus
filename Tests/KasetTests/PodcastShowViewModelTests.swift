import Foundation
import Testing

@testable import Kaset

/// The podcast show page's model.
///
/// The page is opened with the show the navigation carried, and that is what must be drawable in the
/// first frame — the reader clicked a show with a name, an author and artwork, so none of that should
/// wait for the episode request.
@Suite(.serialized)
@MainActor
struct PodcastShowViewModelTests {
    // MARK: - Fixtures

    private static let navigationShow = PodcastShow(
        id: "MPSPPLnav-seeded",
        title: "Navigation Show",
        author: "Navigation Author",
        description: "Carried by the navigation",
        thumbnailURL: URL(string: "https://example.com/navigation.jpg"),
        episodeCount: 12
    )

    private static func makeEpisode(
        id: String,
        title: String = "Episode",
        durationSeconds: Int? = nil
    ) -> PodcastEpisode {
        PodcastEpisode(
            id: id,
            title: title,
            showTitle: "Navigation Show",
            showBrowseId: nil,
            description: nil,
            thumbnailURL: nil,
            publishedDate: nil,
            duration: nil,
            durationSeconds: durationSeconds,
            playbackProgress: 0,
            isPlayed: false
        )
    }

    private static func makeDetail(
        show: PodcastShow,
        episodes: [PodcastEpisode] = [],
        continuationToken: String? = nil,
        isSubscribed: Bool = false
    ) -> PodcastShowDetail {
        PodcastShowDetail(
            show: show,
            episodes: episodes,
            continuationToken: continuationToken,
            isSubscribed: isSubscribed
        )
    }

    // MARK: - First frame

    @Test("The header is readable before any request")
    func headerIsReadableBeforeTheFirstRequest() {
        let viewModel = PodcastShowViewModel(show: Self.navigationShow, client: MockYTMusicClient())

        #expect(viewModel.show.title == "Navigation Show")
        #expect(viewModel.show.author == "Navigation Author")
        #expect(viewModel.show.thumbnailURL == Self.navigationShow.thumbnailURL)
        #expect(viewModel.loadingState == .idle)
        #expect(viewModel.episodes.isEmpty)
    }

    // MARK: - Load

    @Test("A loaded page installs its episodes, continuation and subscription")
    func loadInstallsThePage() async {
        let client = MockYTMusicClient()
        client.podcastShowDetail = Self.makeDetail(
            show: Self.navigationShow,
            episodes: [Self.makeEpisode(id: "episode-1"), Self.makeEpisode(id: "episode-2")],
            continuationToken: "next-page",
            isSubscribed: true
        )
        let viewModel = PodcastShowViewModel(show: Self.navigationShow, client: client)

        await viewModel.load()

        #expect(viewModel.loadingState == .loaded)
        #expect(viewModel.episodes.count == 2)
        #expect(viewModel.continuationToken == "next-page")
        #expect(viewModel.isSubscribed)
        #expect(client.getPodcastShowCallCount == 1)
    }

    @Test("Fields the fetched record leaves blank are filled from the show the navigation carried")
    func loadFillsBlankHeaderFieldsFromNavigation() async {
        let client = MockYTMusicClient()
        client.podcastShowDetail = Self.makeDetail(
            show: PodcastShow(
                id: "",
                title: "Unknown Show",
                author: "  ",
                description: nil,
                thumbnailURL: nil,
                episodeCount: nil
            )
        )
        let viewModel = PodcastShowViewModel(show: Self.navigationShow, client: client)

        await viewModel.load()

        #expect(viewModel.show.id == Self.navigationShow.id)
        #expect(viewModel.show.title == "Navigation Show")
        #expect(viewModel.show.author == "Navigation Author")
        #expect(viewModel.show.description == "Carried by the navigation")
        #expect(viewModel.show.thumbnailURL == Self.navigationShow.thumbnailURL)
        #expect(viewModel.show.episodeCount == 12)
    }

    @Test("A second load does not re-request a page that has loaded")
    func loadedPageIsNotRefetched() async {
        let client = MockYTMusicClient()
        client.podcastShowDetail = Self.makeDetail(show: Self.navigationShow)

        let viewModel = PodcastShowViewModel(show: Self.navigationShow, client: client)
        await viewModel.load()
        await viewModel.load()

        #expect(client.getPodcastShowCallCount == 1)
    }

    @Test("Overlapping loads share one request")
    func concurrentLoadsShareOneRequest() async {
        let client = MockYTMusicClient()
        client.podcastShowDelay = .milliseconds(100)
        client.podcastShowDetail = Self.makeDetail(
            show: Self.navigationShow,
            episodes: [Self.makeEpisode(id: "episode-1")]
        )
        let viewModel = PodcastShowViewModel(show: Self.navigationShow, client: client)

        async let first: Void = viewModel.load()
        async let second: Void = viewModel.load()
        _ = await (first, second)

        #expect(client.getPodcastShowCallCount == 1)
        #expect(viewModel.episodes.count == 1)
    }

    @Test("A failed first load is stated as an error, not as an empty show")
    func failedFirstLoadSetsError() async {
        let client = MockYTMusicClient()
        client.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))
        let viewModel = PodcastShowViewModel(show: Self.navigationShow, client: client)

        await viewModel.load()

        if case .error = viewModel.loadingState {
            // Expected: the page keeps its header and offers a retry.
        } else {
            Issue.record("Expected an error state but got \(viewModel.loadingState)")
        }
        #expect(viewModel.show.title == "Navigation Show")
    }

    // MARK: - Refresh

    @Test("A failed refresh keeps the episodes already on screen")
    func failedRefreshKeepsTheEpisodes() async {
        let client = MockYTMusicClient()
        client.podcastShowDetail = Self.makeDetail(
            show: Self.navigationShow,
            episodes: [Self.makeEpisode(id: "episode-1")]
        )
        let viewModel = PodcastShowViewModel(show: Self.navigationShow, client: client)
        await viewModel.load()

        client.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))
        await viewModel.refresh()

        #expect(viewModel.loadingState == .loaded)
        #expect(viewModel.episodes.count == 1)
    }

    @Test("A refresh replaces the page with the fresh copy")
    func refreshReplacesThePage() async {
        let client = MockYTMusicClient()
        client.podcastShowDetail = Self.makeDetail(
            show: Self.navigationShow,
            episodes: [Self.makeEpisode(id: "episode-1")]
        )
        let viewModel = PodcastShowViewModel(show: Self.navigationShow, client: client)
        await viewModel.load()

        client.podcastShowDetail = Self.makeDetail(
            show: Self.navigationShow,
            episodes: [Self.makeEpisode(id: "episode-1"), Self.makeEpisode(id: "episode-2")],
            isSubscribed: true
        )
        await viewModel.refresh()

        #expect(client.getPodcastShowCallCount == 2)
        #expect(viewModel.episodes.count == 2)
        #expect(viewModel.isSubscribed)
    }

    // MARK: - Derived state

    @Test("The preview shows five episodes and reports that more exist")
    func previewCapsAtFiveEpisodes() async {
        let client = MockYTMusicClient()
        let episodes = (1 ... 8).map { Self.makeEpisode(id: "episode-\($0)") }
        client.podcastShowDetail = Self.makeDetail(show: Self.navigationShow, episodes: episodes)
        let viewModel = PodcastShowViewModel(show: Self.navigationShow, client: client)

        await viewModel.load()

        #expect(viewModel.previewEpisodes.count == PodcastShowViewModel.previewEpisodeCount)
        #expect(viewModel.hasMoreEpisodes)
        #expect(viewModel.episodeCount == 12)
    }

    @Test("A show that fits in the preview offers no full list")
    func shortShowOffersNoFullList() async {
        let client = MockYTMusicClient()
        let show = PodcastShow(
            id: "MPSPPLshort",
            title: "Short Show",
            author: nil,
            description: nil,
            thumbnailURL: nil,
            episodeCount: nil
        )
        client.podcastShowDetail = Self.makeDetail(
            show: show,
            episodes: [Self.makeEpisode(id: "episode-1")]
        )
        let viewModel = PodcastShowViewModel(show: show, client: client)

        await viewModel.load()

        #expect(!viewModel.hasMoreEpisodes)
        #expect(viewModel.episodeCount == 1)
    }

    @Test("Episodes play as songs in their own order, once")
    func playableSongsMapEpisodesInOrder() async {
        let client = MockYTMusicClient()
        client.podcastShowDetail = Self.makeDetail(
            show: Self.navigationShow,
            episodes: [
                Self.makeEpisode(id: "episode-1", title: "First", durationSeconds: 3661),
                Self.makeEpisode(id: "episode-2", title: "Second"),
            ]
        )
        let viewModel = PodcastShowViewModel(show: Self.navigationShow, client: client)

        await viewModel.load()
        let songs = viewModel.playableSongs()

        #expect(songs.map(\.videoId) == ["episode-1", "episode-2"])
        #expect(songs.map(\.title) == ["First", "Second"])
        #expect(songs.first?.duration == 3661)
        #expect(songs.first?.artists.first?.name == "Navigation Show")
        // The list is mapped once per episode list, so a second tap hands back the same models.
        #expect(viewModel.playableSongs().map(\.videoId) == songs.map(\.videoId))
    }

    // MARK: - Library

    @Test("Subscribing flips the show into the library")
    func subscribeFlipsState() async {
        let show = PodcastShow(
            id: "MPSPPLtest101",
            title: "Test Show",
            author: nil,
            description: nil,
            thumbnailURL: nil,
            episodeCount: nil
        )
        let client = MockYTMusicClient()
        client.podcastShowDetail = Self.makeDetail(show: show)
        let viewModel = PodcastShowViewModel(show: show, client: client)
        await viewModel.load()

        await viewModel.toggleSubscription(libraryViewModel: nil)

        #expect(viewModel.isSubscribed)
        #expect(viewModel.subscriptionError == nil)
    }
}
