import CoreGraphics
import Foundation
import Observation
import os

/// View model for the podcast show page (`PodcastShowView`).
///
/// The page used to hold every piece of its state itself, and it showed a full-page spinner until the
/// show's episodes arrived — even though the show it was opened with already carried the name, author
/// and artwork the header draws. Its siblings are model-driven pages that paint from what they were
/// handed and fetch the rest (the podcasts discovery page, home, playlists, artists); this follows them.
@MainActor
@Observable
final class PodcastShowViewModel {
    /// The show the page describes. Seeded from navigation, then replaced by the fetched record, so the
    /// header is drawable in the page's first frame.
    private(set) var show: PodcastShow

    /// The show's first page of episodes.
    private(set) var episodes: [PodcastEpisode] = []

    /// Token for the episodes that follow the first page, handed to the full list page.
    private(set) var continuationToken: String?

    /// Loading state of the episode list. The header never waits on it.
    private(set) var loadingState: LoadingState = .idle

    /// Whether the show is in the account's library.
    private(set) var isSubscribed = false

    /// Whether a subscribe/unsubscribe request is in flight.
    private(set) var isSubscribing = false

    /// Error from the last subscribe/unsubscribe request, surfaced as an alert.
    private(set) var subscriptionError: String?

    /// The API client (exposed for the page's rows and the full list page).
    let client: any YTMusicClientProtocol

    /// Number of episodes the page previews before "Show All".
    static let previewEpisodeCount = 5

    /// The show the page was opened with, kept for the fields a fetched record can leave blank.
    private let navigationShow: PodcastShow
    private let logger = DiagnosticsLogger.api

    /// The request on its way, shared so a second `load()` never issues a second request for the same
    /// show.
    private var inFlightLoad: Task<Void, Never>?

    /// Bumped when the page's list is replaced or abandoned. A response requested before the bump
    /// belongs to a page the reader has already left and must not land on screen.
    private var loadGeneration: UInt64 = 0

    /// The episodes as the songs they play as, mapped once per episode list rather than once per tap.
    private var mappedSongs: [Song]?

    /// Display size of an episode row's artwork, matching `PodcastEpisodeRow.artworkSize`. The prefetch
    /// warms the slot the rows draw in, not the header's.
    private static let rowArtworkSize: CGFloat = 64

    init(show: PodcastShow, client: any YTMusicClientProtocol) {
        self.show = show
        self.navigationShow = show
        self.client = client
    }

    // MARK: - Loading

    /// Loads the show's episodes, keeping the header the navigation carried on screen throughout.
    ///
    /// A page that has already loaded keeps what it has: only an idle page asks again, which is what
    /// lets the page's `.task` run on every appearance without re-fetching.
    func load() async {
        guard self.loadingState == .idle else { return }

        if let inFlightLoad {
            await inFlightLoad.value
            return
        }

        let generation = self.loadGeneration
        let task = Task { await self.fetchShow(generation: generation) }
        self.inFlightLoad = task
        await task.value
        if generation == self.loadGeneration {
            self.inFlightLoad = nil
        }
    }

    /// Refreshes the page. The episodes already on screen stay there while the new copy is fetched.
    func refresh() async {
        self.loadGeneration &+= 1
        self.inFlightLoad = nil
        // A manual refresh asks for fresh data instead of the cached browse response.
        APICache.shared.invalidate(matching: "browse:")
        await self.fetchShow(generation: self.loadGeneration)
    }

    private func fetchShow(generation: UInt64) async {
        if self.episodes.isEmpty {
            self.loadingState = .loading
        }
        self.logger.info("Loading podcast show: \(self.navigationShow.id)")

        do {
            let detail = try await self.client.getPodcastShow(browseId: self.navigationShow.id)
            guard generation == self.loadGeneration else {
                self.logger.debug("Discarding podcast show loaded for a page that was replaced")
                return
            }
            self.install(detail)
        } catch is CancellationError {
            guard generation == self.loadGeneration else { return }
            self.logger.debug("Podcast show load cancelled")
            self.loadingState = self.episodes.isEmpty ? .idle : .loaded
        } catch {
            guard generation == self.loadGeneration else { return }
            self.logger.error("Failed to load podcast show: \(error.localizedDescription)")
            // A page that already shows its episodes keeps them: a failed refresh is not worth
            // replacing a readable list with an error.
            self.loadingState = self.episodes.isEmpty ? .error(LoadingError(from: error)) : .loaded
        }
    }

    private func install(_ detail: PodcastShowDetail) {
        self.show = self.merging(detail.show)
        self.episodes = detail.episodes
        self.continuationToken = detail.continuationToken
        self.isSubscribed = detail.isSubscribed
        self.mappedSongs = nil
        self.loadingState = .loaded
        self.logger.info(
            "Podcast show loaded: \(detail.episodes.count) episodes, hasMore: \(detail.continuationToken != nil)"
        )
    }

    /// The fetched record with anything it left blank filled from the show the navigation carried.
    private func merging(_ fetched: PodcastShow) -> PodcastShow {
        func filled(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return value
        }

        let title = filled(fetched.title) ?? filled(self.navigationShow.title) ?? fetched.title
        return PodcastShow(
            id: fetched.id.isEmpty ? self.navigationShow.id : fetched.id,
            // The parser writes "Unknown Show" when a page names nothing, which is a gap rather than a
            // title the reader should see over one the navigation already had.
            title: title == "Unknown Show" ? self.navigationShow.title : title,
            author: filled(fetched.author) ?? filled(self.navigationShow.author),
            description: filled(fetched.description) ?? filled(self.navigationShow.description),
            thumbnailURL: fetched.thumbnailURL ?? self.navigationShow.thumbnailURL,
            episodeCount: fetched.episodeCount ?? self.navigationShow.episodeCount
        )
    }

    // MARK: - Derived state

    /// Episodes to show in the preview (limited to `previewEpisodeCount`).
    var previewEpisodes: [PodcastEpisode] {
        Array(self.episodes.prefix(Self.previewEpisodeCount))
    }

    /// Whether "Show All" has anything to open: more episodes loaded than the preview, or a page the
    /// full list can fetch.
    var hasMoreEpisodes: Bool {
        self.episodes.count > Self.previewEpisodeCount || self.continuationToken != nil
    }

    /// The show's episode count when it can be stated: the API's total when it reported one, otherwise
    /// the page's first page. `nil` before the page has loaded, so the header never says "0 episodes" at
    /// a show it has not asked about yet.
    var episodeCount: Int? {
        if let count = self.show.episodeCount, count > 0 {
            return count
        }
        return self.episodes.isEmpty ? nil : self.episodes.count
    }

    /// Every loaded episode as the song it plays as, mapped once per episode list so tapping an episode
    /// does not rebuild the queue's models.
    func playableSongs() -> [Song] {
        if let mappedSongs {
            return mappedSongs
        }
        let songs = self.episodes.map(\.playbackSong)
        self.mappedSongs = songs
        return songs
    }

    /// Warms the artwork of the rows the page is about to draw, so they appear with their pictures
    /// instead of decoding them on the scroll path.
    func prefetchArtwork() async {
        let urls = self.previewEpisodes.compactMap(\.thumbnailURL)
        guard !urls.isEmpty else { return }
        await ImageCache.shared.prefetch(
            urls: urls,
            targetSize: CGSize(width: Self.rowArtworkSize, height: Self.rowArtworkSize)
        )
    }

    // MARK: - Library

    /// Adds the show to the library, or removes it, and reports a failure to the page's alert.
    func toggleSubscription(libraryViewModel: LibraryViewModel?) async {
        guard !self.isSubscribing else { return }

        self.isSubscribing = true
        self.subscriptionError = nil
        defer { self.isSubscribing = false }

        do {
            if self.isSubscribed {
                try await SongActionsHelper.unsubscribeFromPodcast(
                    self.show,
                    client: self.client,
                    libraryViewModel: libraryViewModel
                )
                self.isSubscribed = false
            } else {
                try await SongActionsHelper.subscribeToPodcast(
                    self.show,
                    client: self.client,
                    libraryViewModel: libraryViewModel
                )
                self.isSubscribed = true
            }
            self.logger.debug("Podcast subscription is now \(self.isSubscribed)")
        } catch {
            self.logger.error(
                "Failed to toggle podcast subscription for \(self.show.title): \(error.localizedDescription)"
            )
            self.subscriptionError = error.localizedDescription
        }
    }

    /// Clears the subscription error, which is what dismisses the page's alert.
    func dismissSubscriptionError() {
        self.subscriptionError = nil
    }
}
