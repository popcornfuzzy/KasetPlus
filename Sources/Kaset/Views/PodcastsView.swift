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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlayerBar.reservedBand
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

    /// The shelves, as one native collection view — the same shape Home's feed uses (ADR-0046).
    /// One scroll view for the page, AppKit's own horizontal scrolling for the shelves, and recycled
    /// cards in fixed slots instead of a nested scroll view and a mask per shelf.
    private var contentView: some View {
        PodcastFeedCollectionView(
            sections: self.viewModel.sections,
            onSelectShow: { show in self.navigationPath.append(show) },
            onPlayEpisode: { episode in self.playEpisode(episode) }
        )
    }

    // MARK: - Actions

    private func playEpisode(_ episode: PodcastEpisode) {
        DiagnosticsLogger.api.debug(
            "PodcastsView.playEpisode tapped episode '\(episode.title)' with videoId=\(episode.id)"
        )

        Task {
            // Use an explicit queue to avoid stale queue sync selecting a different track.
            await self.playerService.playQueue([episode.playbackSong], startingAt: 0)
        }
    }
}

// MARK: - PodcastShowCard

@available(macOS 26.0, *)
struct PodcastShowCard: View {
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

                // One line, truncated. A card's title is a label on a shelf: wrapped, it made one card
                // taller than the next and every row in the card move with it. At one line every card
                // of a kind is exactly the same height.
                Text(self.show.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Author, drawn even when the show has none, so a missing one cannot change the height.
                Text(self.authorText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: PodcastFeedMetrics.showCardWidth, alignment: .topLeading)
        }
        .buttonStyle(.plain)
    }

    /// The author line's text, blank rather than missing — see the comment above it.
    private var authorText: String {
        guard let author = self.show.author, !author.isEmpty else { return " " }
        return author
    }
}

// MARK: - PodcastEpisodeCard

@available(macOS 26.0, *)
struct PodcastEpisodeCard: View {
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

                // One line, truncated — see `PodcastShowCard`.
                Text(self.episode.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Show name and date, drawn even when the episode carries neither — see
                // `PodcastShowCard`.
                Text(self.metaText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: PodcastFeedMetrics.episodeCardWidth, alignment: .topLeading)
        }
        .buttonStyle(.plain)
    }

    /// "Show • 3d ago", or a blank line when the episode carries neither.
    private var metaText: String {
        let parts = [self.episode.showTitle, self.episode.publishedDate].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? " " : parts.joined(separator: " • ")
    }
}


// MARK: - PodcastShowView

/// Detail view for a podcast show with its episodes.
///
/// The page follows the same shape as the playlist and artist pages: the header is the list's first row
/// (ADR-0023), the episodes are AppKit-backed `List` rows (ADR-0014), and the header's controls are the
/// app's glass controls. Its state lives in `PodcastShowViewModel`, and the header is drawn from the show
/// the navigation carried — so opening a show paints its name, author and artwork in the first frame
/// while the episodes are still on their way.
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

    /// The page's state: the show it was opened with, its first page of episodes and its subscription.
    ///
    /// The model is built in `init`, not in `.task`, so the header the navigation carried is on screen
    /// in the page's first frame instead of after the request — the shape `PlaylistDetailView` and
    /// `ArtistDetailView` already use.
    @State private var viewModel: PodcastShowViewModel
    @State private var isScrolling = false

    /// Edge length of the header artwork, shared with the playlist and artist headers.
    private static let artworkSize: CGFloat = 180

    init(
        show: PodcastShow,
        client: any YTMusicClientProtocol,
        onShowAllEpisodes: @escaping (AllEpisodesDestination) -> Void
    ) {
        self.show = show
        self.client = client
        self.onShowAllEpisodes = onShowAllEpisodes
        _viewModel = State(initialValue: PodcastShowViewModel(show: show, client: client))
    }

    var body: some View {
        self.contentView
            .accentBackground(from: self.viewModel.show.thumbnailURL)
            .pageTitle(id: "podcast-\(self.show.id)", title: self.viewModel.show.title)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlayerBar.reservedBand
            }
            .task {
                await self.viewModel.load()
            }
            // Rows decode at their 64 pt slot, so the page warms the artwork it is about to draw rather
            // than decoding it on the scroll path (`PlaylistDetailView` does the same for its rows).
            .task(id: self.viewModel.episodes.count) {
                await self.viewModel.prefetchArtwork()
            }
            .refreshable {
                await self.viewModel.refresh()
            }
            .alert(
                String(localized: "Subscription Error"),
                isPresented: Binding(
                    get: { self.viewModel.subscriptionError != nil },
                    set: { if !$0 { self.viewModel.dismissSubscriptionError() } }
                )
            ) {
                Button(String(localized: "OK")) { self.viewModel.dismissSubscriptionError() }
            } message: {
                Text(self.viewModel.subscriptionError ?? String(localized: "An unknown error occurred"))
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

            self.episodeContent
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
                url: self.viewModel.show.thumbnailURL,
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

                Text(self.viewModel.show.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)

                if let author = self.viewModel.show.author, !author.isEmpty {
                    Text(author)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                if let description = self.viewModel.show.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }

                if let count = self.viewModel.episodeCount {
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
            .disabled(self.viewModel.episodes.isEmpty)

            Button {
                Task {
                    await self.viewModel.toggleSubscription(libraryViewModel: self.libraryViewModel)
                }
            } label: {
                if self.viewModel.isSubscribing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(
                        self.viewModel.isSubscribed
                            ? String(localized: "In Library")
                            : String(localized: "Add to Library"),
                        systemImage: self.viewModel.isSubscribed ? "checkmark" : "plus"
                    )
                }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(self.viewModel.isSubscribing)
        }
    }

    private var episodesHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Episodes")
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            if self.viewModel.hasMoreEpisodes {
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

        ForEach(Array(self.viewModel.previewEpisodes.enumerated()), id: \.element.id) { index, episode in
            PodcastEpisodeRow(
                episode: episode,
                isCurrent: episode.id == currentVideoId,
                isPlaying: isPlaying && episode.id == currentVideoId,
                showsSeparator: index < self.viewModel.previewEpisodes.count - 1,
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

    /// The page's episodes slot: rows once they are here, a loading line while the first page is on its
    /// way, an explanation for a show that has none, and a retry when the request failed.
    ///
    /// The header above it is already readable, so an empty or failed episode list is stated in place
    /// instead of replacing the whole page with a spinner.
    @ViewBuilder
    private var episodeContent: some View {
        if case let .error(error) = self.viewModel.loadingState {
            ErrorView(error: error) {
                Task { await self.viewModel.refresh() }
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 12, leading: 24, bottom: 24, trailing: 24))
            .listRowBackground(Color.clear)
        } else if self.viewModel.episodes.isEmpty, self.viewModel.loadingState == .loaded {
            self.emptyEpisodesView
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 24, leading: 24, bottom: 32, trailing: 24))
                .listRowBackground(Color.clear)
        } else if self.viewModel.episodes.isEmpty {
            self.loadingRow
        } else {
            self.episodeRows
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            FixedProgressView(controlSize: .small)

            Text("Loading episodes…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    // MARK: - Actions

    private func showAllEpisodes() {
        self.onShowAllEpisodes(
            AllEpisodesDestination(
                show: self.viewModel.show,
                episodes: self.viewModel.episodes,
                continuationToken: self.viewModel.continuationToken
            )
        )
    }

    /// Plays an episode and queues the remaining episodes from the show.
    private func playEpisodeInQueue(at index: Int) {
        let songs = self.viewModel.playableSongs()
        Task {
            await self.playerService.playQueue(songs, startingAt: index)
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
            PlayerBar.reservedBand
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
        let songs = self.episodes.map(\.playbackSong)
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
