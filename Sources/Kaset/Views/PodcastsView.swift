import SwiftUI

// MARK: - PodcastsView

/// Podcasts discovery view displaying podcast shows and episodes.
@available(macOS 26.0, *)
struct PodcastsView: View {
    @State var viewModel: PodcastsViewModel
    @Environment(PlayerService.self) private var playerService
    @State private var navigationPath = NavigationPath()
    @State private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        PageNavigationStack(id: "podcasts", path: self.$navigationPath) {
            Group {
                if !self.networkMonitor.isConnected, !self.viewModel.loadingState.hasContent {
                    ErrorView(
                        title: String(localized: "No Connection"),
                        message: String(localized: "Please check your internet connection and try again.")
                    ) {
                        Task { await self.viewModel.refresh() }
                    }
                } else {
                    switch self.viewModel.loadingState {
                    case .idle, .loading:
                        LoadingView(String(localized: "Loading podcasts..."))
                    case .loaded, .loadingMore:
                        self.contentView
                    case let .error(error):
                        ErrorView(error: error) {
                            Task { await self.viewModel.refresh() }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .pageTitle(id: "podcasts", title: String(localized: "Podcasts"))
            // The show page is one of the shared destinations below; registering it here as well put a
            // second `PodcastShow` destination on this stack, and opening a show then re-entered layout
            // and froze the app (ADR-0023).
            .navigationDestinations(client: self.viewModel.client, artistPath: self.$navigationPath)
            // Inside the stack, not outside it: an inset on the stack itself outlives a push and stacks
            // a second bar under the destination's own (`PodcastShowView`, `AllEpisodesView`).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlayerBar()
            }
        }
        .onAppear {
            if self.viewModel.loadingState == .idle {
                Task {
                    await self.viewModel.load()
                }
            }
        }
        .refreshable {
            await self.viewModel.refresh()
        }
    }

    // MARK: - Views

    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(self.viewModel.sections) { section in
                    self.sectionView(section)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private func sectionView(_ section: PodcastSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.title2)
                .fontWeight(.semibold)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(section.items) { item in
                        self.itemCard(item)
                    }
                }
            }
            .horizontalRowEdgeFade()
        }
    }

    @ViewBuilder
    private func itemCard(_ item: PodcastSectionItem) -> some View {
        switch item {
        case let .show(show):
            PodcastShowCard(show: show) {
                self.navigationPath.append(show)
            }
        case let .episode(episode):
            PodcastEpisodeCard(episode: episode) {
                self.playEpisode(episode)
            }
        }
    }

    // MARK: - Actions

    private func playEpisode(_ episode: PodcastEpisode) {
        // Create a Song from the episode to play via WebView
        let song = Song(
            id: episode.id,
            title: episode.title,
            artists: episode.showTitle.map { [Artist(id: "podcast", name: $0)] } ?? [],
            album: nil,
            duration: episode.durationSeconds.map { TimeInterval($0) },
            thumbnailURL: episode.thumbnailURL,
            videoId: episode.id
        )

        DiagnosticsLogger.api.debug(
            "PodcastsView.playEpisode tapped episode '\(episode.title)' with videoId=\(episode.id)"
        )

        Task {
            // Use an explicit queue to avoid stale queue sync selecting a different track.
            await self.playerService.playQueue([song], startingAt: 0)
        }
    }
}

// MARK: - PodcastShowCard

@available(macOS 26.0, *)
private struct PodcastShowCard: View {
    let show: PodcastShow
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail
                CachedAsyncImage(url: self.show.thumbnailURL, targetSize: CGSize(width: 160, height: 160)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Title
                Text(self.show.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                // Author
                if let author = show.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 160)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - PodcastEpisodeCard

@available(macOS 26.0, *)
private struct PodcastEpisodeCard: View {
    let episode: PodcastEpisode
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail with play indicator
                ZStack(alignment: .bottomTrailing) {
                    CachedAsyncImage(url: self.episode.thumbnailURL, targetSize: CGSize(width: 200, height: 112)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .frame(width: 200, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    if self.episode.playbackProgress > 0 {
                        VStack {
                            Spacer()
                            PodcastPlaybackProgressBar(
                                progress: self.episode.playbackProgress,
                                isPlayed: self.episode.isPlayed,
                                trackColor: .black.opacity(0.24),
                                fillColor: self.episode.isPlayed ? .white.opacity(0.55) : .white.opacity(0.88),
                                height: 2
                            )
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 5)
                    }

                    // Duration badge
                    if let duration = episode.formattedDuration {
                        Text(duration)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .glassEffect(.regular, in: .rect(cornerRadius: 6))
                            .clipShape(.rect(cornerRadius: 6))
                            .padding(.horizontal, 6)
                            .padding(.bottom, self.episode.playbackProgress > 0 ? 10 : 6)
                    }
                }

                // Title
                Text(self.episode.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                // Show name and date
                HStack(spacing: 4) {
                    if let showTitle = episode.showTitle {
                        Text(showTitle)
                            .lineLimit(1)
                    }
                    if self.episode.showTitle != nil, self.episode.publishedDate != nil {
                        Text("•")
                    }
                    if let date = episode.publishedDate {
                        Text(date)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

            }
            .frame(width: 200)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Podcast Playback

/// The song an episode is played as. Podcast episodes have no album or artist page, so the show's name
/// is carried as the artist — the same shape the episode rows and the fullscreen player already use.
private func podcastSong(for episode: PodcastEpisode) -> Song {
    Song(
        id: episode.id,
        title: episode.title,
        artists: episode.showTitle.map { [Artist(id: "podcast", name: $0)] } ?? [],
        album: nil,
        duration: episode.durationSeconds.map { TimeInterval($0) },
        thumbnailURL: episode.thumbnailURL,
        videoId: episode.id
    )
}

// MARK: - PodcastShowView

/// Detail view for a podcast show with its episodes.
///
/// The page follows the same shape as the playlist and artist pages: the header is the list's first row
/// (ADR-0023), the episodes are AppKit-backed `List` rows (ADR-0014), and the header's controls are the
/// app's glass controls. Loading and failure use the shared `LoadingView` / `ErrorView`, so opening a
/// show works the same way as opening any other detail page.
@available(macOS 26.0, *)
struct PodcastShowView: View {
    let show: PodcastShow
    let client: any YTMusicClientProtocol

    /// Pushes the show's full episode list onto the enclosing stack's path.
    ///
    /// This page is a destination of that stack already, and such a page declares no destination of its
    /// own: a second one on the same stack re-enters layout and freezes the app (ADR-0023). The stack
    /// registers `AllEpisodesDestination` and hands the path down here, the way it hands
    /// `PlaylistDetailView` its `onNavigateToArtist`.
    let onShowAllEpisodes: (AllEpisodesDestination) -> Void

    @Environment(PlayerService.self) private var playerService
    @Environment(LibraryViewModel.self) private var libraryViewModel: LibraryViewModel?

    @State private var episodes: [PodcastEpisode] = []
    @State private var continuationToken: String?
    @State private var loadingState: LoadingState = .idle
    @State private var isSubscribed: Bool = false
    @State private var isSubscribing: Bool = false
    @State private var subscriptionError: String?
    @State private var isScrolling = false

    /// Number of episodes the page previews before "Show All".
    private static let previewEpisodeCount = 5

    /// Edge length of the header artwork, shared with the playlist and artist headers.
    private static let artworkSize: CGFloat = 180

    var body: some View {
        Group {
            switch self.loadingState {
            case .idle, .loading:
                LoadingView(String(localized: "Loading podcast..."))
            case .loaded, .loadingMore:
                self.contentView
            case let .error(error):
                ErrorView(error: error) {
                    Task { await self.loadShow(force: true) }
                }
            }
        }
        .accentBackground(from: self.show.thumbnailURL)
        .pageTitle(id: "podcast-\(self.show.id)", title: self.show.title)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .error = self.loadingState {} else {
                PlayerBar()
            }
        }
        .task {
            await self.loadShow()
        }
        .refreshable {
            await self.loadShow(force: true)
        }
        .alert(
            String(localized: "Subscription Error"),
            isPresented: Binding(
                get: { self.subscriptionError != nil },
                set: { if !$0 { self.subscriptionError = nil } }
            )
        ) {
            Button(String(localized: "OK")) { self.subscriptionError = nil }
        } message: {
            Text(self.subscriptionError ?? String(localized: "An unknown error occurred"))
        }
    }

    // MARK: - Views

    /// The header is the list's first row, so the table lays it out and it scrolls away with the
    /// episodes; see ADR-0023 for why it is not a section header.
    private var contentView: some View {
        List {
            self.headerView
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 24, bottom: 20, trailing: 24))
                .listRowBackground(Color.clear)

            Divider()
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                .listRowBackground(Color.clear)

            self.episodesHeader
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 20, leading: 24, bottom: 8, trailing: 24))
                .listRowBackground(Color.clear)

            if self.previewEpisodes.isEmpty {
                self.emptyEpisodesView
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 24, leading: 24, bottom: 32, trailing: 24))
                    .listRowBackground(Color.clear)
            } else {
                self.episodeRows
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Rows must not swap their hover highlight while the list scrolls under a stationary pointer.
        .onScrollPhaseChange { _, newPhase, _ in
            let scrolling = newPhase != .idle
            if scrolling != self.isScrolling {
                self.isScrolling = scrolling
            }
        }
    }

    private var headerView: some View {
        HStack(alignment: .top, spacing: 20) {
            CachedAsyncImage(
                url: self.show.thumbnailURL,
                identity: self.show.id
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: Self.artworkSize, height: Self.artworkSize)
            .clipShape(.rect(cornerRadius: 12))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .fadeIn(duration: 0.3)

            VStack(alignment: .leading, spacing: 8) {
                Text("Podcast")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text(self.show.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)

                if let author = self.show.author, !author.isEmpty {
                    Text(author)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                if let description = self.show.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }

                if let count = self.episodeCount {
                    Text(count == 1 ? "1 episode" : "\(count) episodes")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                self.actionRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                self.playEpisodeInQueue(at: 0)
            } label: {
                Label("Play Latest", systemImage: "play.fill")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(self.episodes.isEmpty)

            Button {
                Task { await self.toggleSubscription() }
            } label: {
                if self.isSubscribing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(
                        self.isSubscribed ? String(localized: "In Library") : String(localized: "Add to Library"),
                        systemImage: self.isSubscribed ? "checkmark" : "plus"
                    )
                }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(self.isSubscribing)
        }
    }

    private var episodesHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Episodes")
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            if self.episodes.count > Self.previewEpisodeCount || self.continuationToken != nil {
                Button {
                    self.showAllEpisodes()
                } label: {
                    HStack(spacing: 2) {
                        Text("Show All")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder
    private var episodeRows: some View {
        let currentVideoId = self.playerService.currentTrack?.videoId
        let isPlaying = self.playerService.isPlaying

        ForEach(Array(self.previewEpisodes.enumerated()), id: \.element.id) { index, episode in
            PodcastEpisodeRow(
                episode: episode,
                isCurrent: episode.id == currentVideoId,
                isPlaying: isPlaying && episode.id == currentVideoId,
                showsSeparator: index < self.previewEpisodes.count - 1,
                isScrolling: self.isScrolling
            ) {
                self.playEpisodeInQueue(at: index)
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private var emptyEpisodesView: some View {
        ContentUnavailableView {
            Label("No Episodes", systemImage: "waveform")
        } description: {
            Text("This show has no episodes yet.")
        }
        .frame(maxWidth: .infinity)
    }

    /// Episodes to show in the preview (limited to previewEpisodeCount).
    private var previewEpisodes: [PodcastEpisode] {
        Array(self.episodes.prefix(Self.previewEpisodeCount))
    }

    /// The show's episode count when it can be stated: the API's total when it reported one, otherwise
    /// the page's first page. `nil` before the page has loaded, so the header never says "0 episodes" at
    /// a show it has not asked about yet.
    private var episodeCount: Int? {
        if let count = self.show.episodeCount, count > 0 {
            return count
        }
        return self.episodes.isEmpty ? nil : self.episodes.count
    }

    // MARK: - Actions

    private func showAllEpisodes() {
        self.onShowAllEpisodes(
            AllEpisodesDestination(
                show: self.show,
                episodes: self.episodes,
                continuationToken: self.continuationToken
            )
        )
    }

    private func loadShow(force: Bool = false) async {
        if !force, self.loadingState != .idle {
            return
        }
        // A refresh keeps the page on screen: only a page with nothing to show flips to the spinner.
        if self.episodes.isEmpty {
            self.loadingState = .loading
        }

        do {
            let showDetail = try await self.client.getPodcastShow(browseId: self.show.id)
            self.episodes = showDetail.episodes
            self.continuationToken = showDetail.continuationToken
            self.isSubscribed = showDetail.isSubscribed
            self.loadingState = .loaded
        } catch {
            DiagnosticsLogger.api.error("Failed to load podcast show: \(error.localizedDescription)")
            if self.episodes.isEmpty {
                self.loadingState = .error(LoadingError(from: error))
            }
        }
    }

    /// Plays an episode and queues the remaining episodes from the show.
    private func playEpisodeInQueue(at index: Int) {
        let songs = self.episodes.map { podcastSong(for: $0) }
        Task {
            await self.playerService.playQueue(songs, startingAt: index)
        }
    }

    private func toggleSubscription() async {
        self.isSubscribing = true
        defer { self.isSubscribing = false }

        DiagnosticsLogger.api.debug("toggleSubscription called, isSubscribed=\(self.isSubscribed), showId=\(self.show.id)")

        do {
            if self.isSubscribed {
                try await SongActionsHelper.unsubscribeFromPodcast(
                    self.show,
                    client: self.client,
                    libraryViewModel: self.libraryViewModel
                )
                self.isSubscribed = false
                DiagnosticsLogger.api.debug("Unsubscribe completed, isSubscribed now=\(self.isSubscribed)")
            } else {
                try await SongActionsHelper.subscribeToPodcast(
                    self.show,
                    client: self.client,
                    libraryViewModel: self.libraryViewModel
                )
                self.isSubscribed = true
                DiagnosticsLogger.api.debug("Subscribe completed, isSubscribed now=\(self.isSubscribed)")
            }
        } catch {
            let errorMessage = error.localizedDescription
            DiagnosticsLogger.api.error(
                "Failed to toggle podcast subscription for \(self.show.title): \(errorMessage)"
            )
            self.subscriptionError = errorMessage
        }
    }
}

// MARK: - PodcastEpisodeRow

/// One episode of a show, drawn as an AppKit-backed `List` row.
///
/// The row fills the list's width and paints its own hover highlight, like `PlaylistTrackRow`: the
/// highlight spans the row rather than only the label inside it, and the divider starts at the title
/// column rather than at the edge of the page.
@available(macOS 26.0, *)
struct PodcastEpisodeRow: View {
    let episode: PodcastEpisode
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    var showsSeparator: Bool = true
    var isScrolling: Bool = false
    let action: () -> Void

    /// Display size of the episode artwork. `ImageCache` doubles it for Retina, so passing the display
    /// size keeps the cache from decoding a bitmap far larger than the slot.
    private static let artworkSize: CGFloat = 64
    /// Horizontal inset of the row's content, matching the page's list rows.
    private static let contentInset: CGFloat = 24
    private static let columnSpacing: CGFloat = 12

    @State private var isPointerInside = false

    private var showsHighlight: Bool {
        self.isPointerInside && !self.isScrolling
    }

    /// Where the title column starts, which is where the row's divider starts too.
    private var titleLeadingInset: CGFloat {
        Self.contentInset + Self.artworkSize + Self.columnSpacing
    }

    var body: some View {
        Button(action: self.action) {
            HStack(alignment: .top, spacing: Self.columnSpacing) {
                self.artwork
                self.info
            }
            .padding(.horizontal, Self.contentInset)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Rectangle().fill(self.showsHighlight ? Color.primary.opacity(0.06) : .clear))
        .animation(AppAnimation.quick, value: self.showsHighlight)
        .onHover { hovering in
            self.isPointerInside = hovering
        }
        .overlay(alignment: .bottom) {
            if self.showsSeparator {
                Divider()
                    .padding(.leading, self.titleLeadingInset)
            }
        }
        .help("Play episode")
    }

    private var artwork: some View {
        CachedAsyncImage(
            url: self.episode.thumbnailURL,
            identity: self.episode.id,
            targetSize: CGSize(width: Self.artworkSize, height: Self.artworkSize)
        ) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: Self.artworkSize, height: Self.artworkSize)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            if self.isCurrent {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            } else if self.showsHighlight {
                Circle()
                    .fill(.black.opacity(0.45))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if self.isCurrent, self.isPlaying {
                Image(systemName: "waveform")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Circle().fill(Color.accentColor))
                    .offset(x: -3, y: 3)
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(self.episode.title)
                    .font(.headline)
                    .lineLimit(2)

                Spacer(minLength: 8)

                if let duration = self.episode.formattedDuration {
                    Text(duration)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if let description = self.episode.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if self.episode.publishedDate != nil || self.episode.isPlayed {
                HStack(spacing: 6) {
                    if let date = self.episode.publishedDate {
                        Text(date)
                    }

                    Spacer(minLength: 8)

                    if self.episode.isPlayed {
                        Label("Played", systemImage: "checkmark.circle.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if self.episode.playbackProgress > 0 {
                PodcastPlaybackProgressBar(
                    progress: self.episode.playbackProgress,
                    isPlayed: self.episode.isPlayed,
                    trackColor: .primary.opacity(0.08),
                    fillColor: self.episode.isPlayed ? .secondary.opacity(0.5) : .accentColor.opacity(0.7),
                    height: 3
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(macOS 26.0, *)
private struct PodcastPlaybackProgressBar: View {
    let progress: Double
    let isPlayed: Bool
    let trackColor: Color
    let fillColor: Color
    let height: CGFloat

    private var clampedProgress: CGFloat {
        CGFloat(min(max(self.progress, 0), 1))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(self.trackColor)

                Capsule()
                    .fill(self.fillColor)
                    .frame(width: geometry.size.width * self.clampedProgress)
            }
        }
        .frame(height: self.height)
        .accessibilityHidden(true)
    }
}

// MARK: - AllEpisodesDestination

/// Navigation destination for the all episodes view.
struct AllEpisodesDestination: Hashable {
    let show: PodcastShow
    let episodes: [PodcastEpisode]
    let continuationToken: String?

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.show.id)
    }

    static func == (lhs: AllEpisodesDestination, rhs: AllEpisodesDestination) -> Bool {
        lhs.show.id == rhs.show.id
    }
}

// MARK: - AllEpisodesView

/// The full episode list of a show, with the same list and row treatment as the show page.
@available(macOS 26.0, *)
struct AllEpisodesView: View {
    let show: PodcastShow
    let client: any YTMusicClientProtocol

    @Environment(PlayerService.self) private var playerService
    @State private var episodes: [PodcastEpisode]
    @State private var currentContinuationToken: String?
    @State private var isLoadingMore = false
    @State private var loadMoreError: String?
    @State private var isScrolling = false

    init(
        show: PodcastShow,
        initialEpisodes: [PodcastEpisode],
        continuationToken: String?,
        client: any YTMusicClientProtocol
    ) {
        self.show = show
        self.client = client
        // The parent has already loaded the first page; seeding the state means the page opens with its
        // rows rather than an empty frame that fills in a turn later.
        _episodes = State(initialValue: initialEpisodes)
        _currentContinuationToken = State(initialValue: continuationToken)
    }

    var body: some View {
        List {
            self.headerView
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 24, bottom: 16, trailing: 24))
                .listRowBackground(Color.clear)

            Divider()
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                .listRowBackground(Color.clear)

            if self.episodes.isEmpty {
                self.emptyEpisodesView
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 24, leading: 24, bottom: 32, trailing: 24))
                    .listRowBackground(Color.clear)
            } else {
                self.episodeRows
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accentBackground(from: self.show.thumbnailURL)
        .pageTitle(id: "all-episodes-\(self.show.id)", title: String(localized: "All Episodes"))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
        }
        .onScrollPhaseChange { _, newPhase, _ in
            let scrolling = newPhase != .idle
            if scrolling != self.isScrolling {
                self.isScrolling = scrolling
            }
        }
    }

    private var headerView: some View {
        HStack(spacing: 16) {
            CachedAsyncImage(
                url: self.show.thumbnailURL,
                identity: self.show.id,
                targetSize: CGSize(width: 64, height: 64)
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 64, height: 64)
            .clipShape(.rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(self.show.title)
                    .font(.title3)
                    .fontWeight(.semibold)

                if let author = self.show.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                self.playEpisodeInQueue(at: 0)
            } label: {
                Label("Play All", systemImage: "play.fill")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(self.episodes.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var episodeRows: some View {
        let currentVideoId = self.playerService.currentTrack?.videoId
        let isPlaying = self.playerService.isPlaying

        ForEach(Array(self.episodes.enumerated()), id: \.element.id) { index, episode in
            PodcastEpisodeRow(
                episode: episode,
                isCurrent: episode.id == currentVideoId,
                isPlaying: isPlaying && episode.id == currentVideoId,
                showsSeparator: index < self.episodes.count - 1,
                isScrolling: self.isScrolling
            ) {
                self.playEpisodeInQueue(at: index)
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            // The sentinel belongs to the last row, so the list realizes it only when the reader has
            // reached the bottom — and the next page's last row realizes a new one.
            if index == self.episodes.count - 1 {
                self.paginationRow
            }
        }
    }

    private var emptyEpisodesView: some View {
        ContentUnavailableView {
            Label("No Episodes", systemImage: "waveform")
        } description: {
            Text("This show has no episodes yet.")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var paginationRow: some View {
        if let error = self.loadMoreError {
            VStack(spacing: 10) {
                Text("Couldn't load more episodes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button(String(localized: "Try Again")) {
                    Task { await self.loadMoreEpisodes() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .help(error)
        } else if self.currentContinuationToken != nil {
            HStack(spacing: 8) {
                FixedProgressView(controlSize: .small)

                Text("Loading more episodes…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .task {
                await self.loadMoreEpisodes()
            }
        }
    }

    private func loadMoreEpisodes() async {
        guard !self.isLoadingMore, let token = self.currentContinuationToken else { return }
        self.isLoadingMore = true
        self.loadMoreError = nil
        defer { self.isLoadingMore = false }

        do {
            let continuation = try await self.client.getPodcastEpisodesContinuation(token: token)
            self.episodes.append(contentsOf: continuation.episodes)
            self.currentContinuationToken = continuation.continuationToken
            DiagnosticsLogger.api.info("Loaded \(continuation.episodes.count) more episodes")
        } catch {
            self.loadMoreError = error.localizedDescription
            DiagnosticsLogger.api.error("Failed to load more episodes: \(error.localizedDescription)")
        }
    }

    /// Plays an episode and queues the remaining episodes.
    private func playEpisodeInQueue(at index: Int) {
        let songs = self.episodes.map { podcastSong(for: $0) }
        Task {
            await self.playerService.playQueue(songs, startingAt: index)
        }
    }
}


#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    PodcastsView(viewModel: PodcastsViewModel(client: client))
        .environment(PlayerService())
}
