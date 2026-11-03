import SwiftUI

// MARK: - LibraryFilter

/// Filter options for the Library view.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case playlists = "Playlists"
    case artists = "Artists"
    case podcasts = "Podcasts"

    var id: String {
        self.rawValue
    }

    var icon: String {
        switch self {
        case .all: "square.grid.2x2"
        case .playlists: "music.note.list"
        case .artists: "person.fill"
        case .podcasts: "mic.fill"
        }
    }

    var displayName: String {
        switch self {
        case .all:
            String(localized: "All")
        case .playlists:
            String(localized: "Playlists")
        case .artists:
            String(localized: "Artists")
        case .podcasts:
            String(localized: "Podcasts")
        }
    }
}

// MARK: - LibrarySortOrder

/// How the library grid is ordered.
enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case titleAscending
    case titleDescending
    case type

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .titleAscending: String(localized: "Title (A–Z)")
        case .titleDescending: String(localized: "Title (Z–A)")
        case .type: String(localized: "Type")
        }
    }
}

// MARK: - LibraryView

/// Library view displaying user's playlists and podcast shows.
@available(macOS 26.0, *)
struct LibraryView: View {
    @State var viewModel: LibraryViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @State private var networkMonitor = NetworkMonitor.shared

    @State private var navigationPath = NavigationPath()
    @State private var selectedFilter: LibraryFilter = .all
    @State private var showCreatePlaylistPopover = false
    @State private var searchText = ""
    @State private var sortOrder: LibrarySortOrder = .titleAscending

    /// Height shared by every control in the filter row — the type chips, the search pill and the sort
    /// pill — so the row reads as one line rather than three heights.
    private static let filterControlHeight: CGFloat = 32

    var body: some View {
        PageNavigationStack(id: "library", path: self.$navigationPath) {
            Group {
                if !self.networkMonitor.isConnected {
                    ErrorView(
                        title: String(localized: "No Connection"),
                        message: String(localized: "Please check your internet connection and try again.")
                    ) {
                        Task { await self.performRefresh() }
                    }
                } else {
                    switch self.viewModel.loadingState {
                    case .idle, .loading:
                        LoadingView(String(localized: "Loading your library..."))
                    case .loaded, .loadingMore:
                        self.contentView
                    case let .error(error):
                        ErrorView(error: error) {
                            Task { await self.performRefresh() }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .pageTitle(id: "library", title: String(localized: "Library"))
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(
                    playlist: playlist,
                    viewModel: PlaylistDetailViewModel(
                        playlist: playlist,
                        client: self.viewModel.client
                    ),
                    onNavigateToArtist: { artist in self.navigationPath.append(artist) }
                )
            }
            .navigationDestination(for: Artist.self) { artist in
                ArtistDetailView(
                    artist: artist,
                    viewModel: ArtistDetailViewModel(
                        artist: artist,
                        client: self.viewModel.client,
                        libraryViewModel: self.viewModel
                    )
                )
            }
            .navigationDestination(for: PodcastShow.self) { show in
                PodcastShowView(show: show, client: self.viewModel.client)
            }
            // Inside the stack, not outside it: an inset on the stack itself outlives a push and stacks
            // a second bar under the destination's own. See `PlayerBar`.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlayerBar()
            }
        }
        .environment(self.viewModel)
        .task {
            if self.viewModel.loadingState == .idle {
                await self.viewModel.load()
            }
            await self.viewModel.reloadIfNeededOnActivation()
        }
        .task(id: "\(self.navigationPath.count)-\(self.viewModel.activationReloadGeneration)") {
            guard self.navigationPath.isEmpty else { return }
            await self.viewModel.reloadIfNeededOnActivation()
        }
        .refreshable {
            await self.performRefresh()
        }
        // The page's refresh lives in the window's toolbar, bounded by the Now Playing column's divider
        // (see `PageToolbarContribution`), so it can never be drawn over the column.
        .pageToolbar(id: "library") {
            PageRefreshButton(
                help: "Refresh Library",
                isRefreshing: { self.viewModel.isRefreshing },
                action: { Task { await self.viewModel.performRefresh() } }
            )
        }
    }

    // MARK: - Views

    private var contentView: some View {
        self.scrollingContent
    }

    private var scrollingContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                // Filter chips, search, and sort share one row.
                self.filterChips

                // Combined grid with filtered content
                self.libraryGrid
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    /// Type chips, with the text filter and the sort menu on the same line: the row is the library's
    /// whole toolbar, so the grid starts directly beneath it.
    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(LibraryFilter.allCases) { filter in
                self.filterChip(filter)
            }

            Spacer(minLength: 12)

            self.searchField
            self.sortMenu
        }
    }

    /// Compact text filter, styled like the playlist pages' search: a glyph, a plain field and a clear
    /// button, sized so it never stretches the row.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField(String(localized: "Filter library"), text: self.$searchText)
                .textFieldStyle(.plain)
                .frame(width: 140)

            if !self.searchText.isEmpty {
                Button {
                    self.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear filter"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.filterControlHeight)
        .background {
            Capsule()
                .fill(Color.secondary.opacity(0.15))
        }
    }

    /// Sort menu matching the playlist pages': a static label, with the active order check-marked in
    /// the menu instead of spelled out in the row. It carries no fill of its own — a borderless menu
    /// label has no chrome, and the bare label is lighter beside the filled search pill.
    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySortOrder.allCases) { order in
                Toggle(order.displayName, isOn: Binding(
                    get: { self.sortOrder == order },
                    set: { isSelected in
                        guard isSelected else { return }
                        self.sortOrder = order
                    }
                ))
            }
        } label: {
            Label(String(localized: "Sort"), systemImage: "arrow.up.arrow.down")
                .padding(.horizontal, 8)
                .frame(height: Self.filterControlHeight)
                .contentShape(Rectangle())
        }
        // Without this the menu keeps macOS's own pull-down pill and chevron over the capsule above.
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Sort by \(self.sortOrder.displayName)"))
    }

    private func performRefresh() async {
        await self.viewModel.performRefresh()
    }

    private func filterChip(_ filter: LibraryFilter) -> some View {
        let isSelected = self.selectedFilter == filter

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                self.selectedFilter = filter
            }
        } label: {
            Text(filter.displayName)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 16)
                .frame(height: Self.filterControlHeight)
                .background {
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                }
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    /// All library items combined, filtered by type and by the text field, then ordered.
    private var filteredItems: [LibraryItem] {
        var items: [LibraryItem] = []

        switch self.selectedFilter {
        case .all:
            items = self.viewModel.playlists.map { .playlist($0) }
                + self.viewModel.artists.map { .artist($0) }
                + self.viewModel.podcastShows.map { .podcast($0) }
        case .playlists:
            items = self.viewModel.playlists.map { .playlist($0) }
        case .artists:
            items = self.viewModel.artists.map { .artist($0) }
        case .podcasts:
            items = self.viewModel.podcastShows.map { .podcast($0) }
        }

        let query = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            items = items.filter { $0.matches(query) }
        }

        return items.sorted(by: self.sortOrder.comparator)
    }

    private var libraryGrid: some View {
        let shouldShowCreatePlaylistCard = (self.selectedFilter == .all || self.selectedFilter == .playlists)
            && self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return Group {
            if self.filteredItems.isEmpty, !shouldShowCreatePlaylistCard {
                self.emptyStateView
            } else {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16),
                ], spacing: 16) {
                    if shouldShowCreatePlaylistCard {
                        self.createPlaylistCard
                    }

                    ForEach(self.filteredItems) { item in
                        switch item {
                        case let .playlist(playlist):
                            self.playlistCard(playlist)
                        case let .artist(artist):
                            self.artistCard(artist)
                        case let .podcast(show):
                            self.podcastCard(show)
                        }
                    }
                }
            }
        }
    }

    private var createPlaylistCard: some View {
        Button {
            self.showCreatePlaylistPopover = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 160, height: 160)

                Text("Add Playlist")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 160, alignment: .leading)

                Text("0 songs", comment: "Playlist track count")
                    .font(.system(size: 11))
                    .opacity(0)
            }
            .frame(width: 160, height: 214, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .popover(isPresented: self.$showCreatePlaylistPopover, arrowEdge: .top) {
            CreatePlaylistPopover(
                client: self.viewModel.client,
                libraryViewModel: self.viewModel
            )
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label(self.emptyStateTitle, systemImage: self.selectedFilter.icon)
        } description: {
            Text(self.emptyStateMessage)
        } actions: {
            if self.searchText.isEmpty, self.selectedFilter == .all || self.selectedFilter == .playlists {
                Button(String(localized: "Create Playlist")) {
                    self.showCreatePlaylistPopover = true
                }
                .buttonStyle(.borderedProminent)
            } else if !self.searchText.isEmpty {
                Button(String(localized: "Clear Filter")) {
                    self.searchText = ""
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .popover(isPresented: self.$showCreatePlaylistPopover, arrowEdge: .bottom) {
            CreatePlaylistPopover(
                client: self.viewModel.client,
                libraryViewModel: self.viewModel
            )
        }
    }

    private var emptyStateTitle: String {
        if !self.searchText.isEmpty {
            return String(localized: "No matches")
        }

        return switch self.selectedFilter {
        case .all:
            String(localized: "Your library is empty")
        case .playlists:
            String(localized: "No playlists yet")
        case .artists:
            String(localized: "No artists yet")
        case .podcasts:
            String(localized: "No podcasts yet")
        }
    }

    private var emptyStateMessage: String {
        if !self.searchText.isEmpty {
            return String(localized: "No playlists, artists or podcasts match that filter.")
        }

        return switch self.selectedFilter {
        case .all:
            String(localized: "Save playlists, follow artists, and subscribe to podcasts on YouTube Music to see them here.")
        case .playlists:
            String(localized: "Create or save playlists on YouTube Music to see them here.")
        case .artists:
            String(localized: "Follow artists on YouTube Music to see them here.")
        case .podcasts:
            String(localized: "Subscribe to podcasts on YouTube Music to see them here.")
        }
    }

    private func playlistCard(_ playlist: Playlist) -> some View {
        let trackCountText = playlist.trackCount.map { "\($0) songs" } ?? "0 songs"
        let shouldShowTrackCount = playlist.trackCount != nil

        return Button {
            self.navigationPath.append(playlist)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail
                CachedAsyncImage(url: playlist.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "music.note.list")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 160, height: 160)
                .clipShape(.rect(cornerRadius: 8))

                // Title
                Text(playlist.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 160, alignment: .leading)

                // Track count
                Text(trackCountText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .opacity(shouldShowTrackCount ? 1 : 0)
            }
            .frame(width: 160, height: 214, alignment: .topLeading)
        }
        .buttonStyle(.plain)
    }

    private func podcastCard(_ show: PodcastShow) -> some View {
        Button {
            self.navigationPath.append(show)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail
                CachedAsyncImage(url: show.thumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "mic.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 160, height: 160)
                .clipShape(.rect(cornerRadius: 8))

                // Title
                Text(show.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 160, alignment: .leading)

                // Author
                if let author = show.author {
                    Text(author)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            FavoritesContextMenu.menuItem(for: show, manager: self.favoritesManager)
        }
    }

    private func artistCard(_ artist: Artist) -> some View {
        Button {
            self.navigationPath.append(artist)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                CachedAsyncImage(url: artist.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 128, height: 128)
                .clipShape(Circle())
                .frame(width: 160)

                Text(artist.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 160)

                Text(String(localized: "Artist"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 160)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            FavoritesContextMenu.menuItem(for: artist, manager: self.favoritesManager)
            ShareContextMenu.menuItem(for: artist)
        }
    }
}

// MARK: - LibraryItem

/// Represents a library item that can be a playlist, artist, or podcast show.
enum LibraryItem: Identifiable {
    case playlist(Playlist)
    case artist(Artist)
    case podcast(PodcastShow)

    var id: String {
        switch self {
        case let .playlist(playlist):
            "playlist-\(playlist.id)"
        case let .artist(artist):
            "artist-\(artist.id)"
        case let .podcast(show):
            "podcast-\(show.id)"
        }
    }

    /// The name the grid orders by.
    var title: String {
        switch self {
        case let .playlist(playlist): playlist.title
        case let .artist(artist): artist.name
        case let .podcast(show): show.title
        }
    }

    /// The type group, for the type-major sort.
    var typeRank: Int {
        switch self {
        case .playlist: 0
        case .artist: 1
        case .podcast: 2
        }
    }

    /// Whether the item's name or author matches the library filter.
    func matches(_ query: String) -> Bool {
        self.searchableText.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private var searchableText: [String] {
        switch self {
        case let .playlist(playlist):
            [playlist.title, playlist.author ?? ""]
        case let .artist(artist):
            [artist.name]
        case let .podcast(show):
            [show.title, show.author ?? ""]
        }
    }
}

// MARK: - LibrarySortOrder + Sorting

extension LibrarySortOrder {
    /// The ordering applied to the library grid.
    var comparator: (LibraryItem, LibraryItem) -> Bool {
        switch self {
        case .titleAscending:
            { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleDescending:
            { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .type:
            { lhs, rhs in
                if lhs.typeRank != rhs.typeRank { return lhs.typeRank < rhs.typeRank }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }
}

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    LibraryView(viewModel: LibraryViewModel(client: client))
        .environment(PlayerService())
        .environment(FavoritesManager.shared)
}
