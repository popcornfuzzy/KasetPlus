import SwiftUI

// MARK: - SearchView

/// Search view for finding music.
@available(macOS 26.0, *)
struct SearchView: View {
    @State var viewModel: SearchViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(SongLikeStatusManager.self) private var likeStatusManager
    @Environment(LibraryViewModel.self) private var libraryViewModel: LibraryViewModel?
    @State private var navigationPath = NavigationPath()
    @State private var networkMonitor = NetworkMonitor.shared

    /// External trigger for focusing the search field (from keyboard shortcut).
    @Binding var focusTrigger: Bool

    @FocusState private var isSearchFieldFocused: Bool

    /// Index of currently selected suggestion for keyboard navigation.
    @State private var selectedSuggestionIndex: Int = -1

    /// Id of the result row the arrow keys are currently on, once they have moved into the results.
    @State private var selectedResultID: String?

    /// Recently searched queries, persisted across launches.
    @State private var searchHistory = SearchHistoryStore.shared

    /// Recently played, loaded only for the empty page's "Jump back in" shelf.
    @State private var recentHistoryViewModel: HistoryViewModel?

    /// Initializes SearchView with optional focus trigger binding.
    init(viewModel: SearchViewModel, focusTrigger: Binding<Bool> = .constant(false)) {
        _viewModel = State(initialValue: viewModel)
        _focusTrigger = focusTrigger
    }

    var body: some View {
        PageNavigationStack(id: "search", path: self.$navigationPath) {
            VStack(spacing: 0) {
                // Search bar
                self.searchBar

                Divider()

                // Content
                self.contentView
            }
            .pageTitle(id: "search", title: String(localized: "Search"))
            .navigationDestinations(client: self.viewModel.client, artistPath: self.$navigationPath)
            // Inside the stack, not outside it, so the bar goes away with the page that owns it instead
            // of stacking onto the pushed page's own. See `PlayerBar`.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlayerBar()
            }
        }
        .onAppear {
            self.isSearchFieldFocused = true
        }
        .onChange(of: self.focusTrigger) { _, newValue in
            if newValue {
                self.isSearchFieldFocused = true
                self.focusTrigger = false
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .top) {
                // Search field
                self.searchField

                // Suggestions dropdown
                if self.viewModel.showSuggestions {
                    self.suggestionsDropdown
                        .padding(.top, 44) // Below search field
                }
            }

            // Filter chips
            if !self.viewModel.results.isEmpty {
                self.filterChips
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .onChange(of: self.viewModel.query) { _, _ in
            self.selectedSuggestionIndex = -1
            self.selectedResultID = nil
            self.viewModel.fetchSuggestions()
        }
        .onChange(of: self.viewModel.suggestions) { _, _ in
            self.selectedSuggestionIndex = -1
        }
        .onChange(of: self.viewModel.selectedFilter) { _, _ in
            self.selectedResultID = nil
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(String(localized: "Search songs, albums, artists..."), text: self.$viewModel.query)
                .textFieldStyle(.plain)
                .focused(self.$isSearchFieldFocused)
                .onSubmit {
                    HapticService.success()
                    if self.selectedSuggestionIndex >= 0,
                       self.selectedSuggestionIndex < self.viewModel.suggestions.count
                    {
                        let suggestion = self.viewModel.suggestions[self.selectedSuggestionIndex]
                        self.searchHistory.record(suggestion.query)
                        self.viewModel.selectSuggestion(suggestion)
                    } else if let item = self.selectedResult {
                        self.handleItemTap(item)
                    } else {
                        self.searchHistory.record(self.viewModel.query)
                        self.viewModel.search()
                    }
                }
                .onKeyPress(.downArrow) {
                    if self.viewModel.showSuggestions {
                        self.selectedSuggestionIndex = min(
                            self.selectedSuggestionIndex + 1,
                            self.viewModel.suggestions.count - 1
                        )
                        return .handled
                    }
                    guard !self.viewModel.filteredItems.isEmpty else { return .ignored }
                    self.moveResultSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    if self.viewModel.showSuggestions {
                        self.selectedSuggestionIndex = max(self.selectedSuggestionIndex - 1, -1)
                        return .handled
                    }
                    guard self.selectedResultID != nil else { return .ignored }
                    self.moveResultSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    if self.viewModel.showSuggestions {
                        self.viewModel.clearSuggestions()
                        return .handled
                    }
                    return .ignored
                }

            if !self.viewModel.query.isEmpty {
                Button {
                    self.viewModel.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear search"))
            }
        }
        .padding(10)
        .glassEffect(.regular, in: .capsule)
    }

    private var suggestionsDropdown: some View {
        VStack(spacing: 0) {
            ForEach(Array(self.viewModel.suggestions.prefix(7).enumerated()), id: \.element.id) { index, suggestion in
                self.suggestionRow(suggestion, index: index)
                if index < min(self.viewModel.suggestions.count, 7) - 1 {
                    Divider()
                        .padding(.leading, 40)
                }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
        .glassEffectTransition(.materialize)
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
    }

    private func suggestionRow(_ suggestion: SearchSuggestion, index: Int) -> some View {
        Button {
            self.searchHistory.record(suggestion.query)
            self.viewModel.selectSuggestion(suggestion)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text(suggestion.query)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.up.left")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(index == self.selectedSuggestionIndex ? Color.accentColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchViewModel.SearchFilter.allCases) { filter in
                    self.filterChip(filter)
                }
            }
        }
    }

    private func filterChip(_ filter: SearchViewModel.SearchFilter) -> some View {
        Button {
            withAnimation(AppAnimation.spring) {
                self.viewModel.selectedFilter = filter
            }
        } label: {
            Text(filter.displayName)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(self.viewModel.selectedFilter == filter ? Color.accentColor : Color.secondary.opacity(0.2))
                .foregroundStyle(self.viewModel.selectedFilter == filter ? .white : .primary)
                .clipShape(.capsule)
        }
        .buttonStyle(.chip(isSelected: self.viewModel.selectedFilter == filter))
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        if !self.networkMonitor.isConnected, !self.viewModel.loadingState.hasContent {
            ErrorView(
                title: String(localized: "No Connection"),
                message: String(localized: "Please check your internet connection and try again.")
            ) {
                self.viewModel.search()
            }
        } else {
            switch self.viewModel.loadingState {
            case .idle:
                self.emptyStateView
            case .loading, .loadingMore:
                LoadingView(String(localized: "Searching..."))
            case .loaded:
                if self.viewModel.filteredItems.isEmpty {
                    self.noResultsView
                } else {
                    self.resultsView
                }
            case let .error(error):
                ErrorView(error: error) {
                    self.viewModel.search()
                }
            }
        }
    }

    private var emptyStateView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !self.viewModel.query.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "Press Return to search"), systemImage: "magnifyingglass")
                    } description: {
                        Text(verbatim: "Search for \u{201C}\(self.viewModel.query)\u{201D}")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    if !self.searchHistory.queries.isEmpty {
                        self.recentSearchesSection
                    }

                    if let items = self.recentlyPlayedItems, !items.isEmpty {
                        self.jumpBackInSection(items)
                    }

                    if self.searchHistory.queries.isEmpty, (self.recentlyPlayedItems?.isEmpty ?? true) {
                        ContentUnavailableView {
                            Label(String(localized: "Search for your favorite music"), systemImage: "magnifyingglass")
                        } description: {
                            Text("Find songs, albums, artists, and playlists")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .task {
            await self.loadRecentHistoryIfNeeded()
        }
    }

    /// The reader's last searches, each one a click away from running again.
    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent searches")
                    .font(.title3)
                    .fontWeight(.semibold)

                Spacer()

                Button(String(localized: "Clear")) {
                    self.searchHistory.clear()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(self.searchHistory.queries, id: \.self) { query in
                    HStack(spacing: 6) {
                        Button {
                            self.runRecentSearch(query)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)

                                Text(query)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            self.searchHistory.remove(query)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Remove from recent searches"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                }
            }
        }
    }

    private func runRecentSearch(_ query: String) {
        self.viewModel.query = query
        self.searchHistory.record(query)
        self.viewModel.search()
    }

    /// A shelf of what the reader played last, so the page can be useful before a query is typed.
    private func jumpBackInSection(_ items: [HomeSectionItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jump back in")
                .font(.title3)
                .fontWeight(.semibold)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(items) { item in
                        HomeSectionItemCard(item: item) {
                            self.openRecentItem(item)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
            .horizontalRowEdgeFade()
        }
    }

    private func openRecentItem(_ item: HomeSectionItem) {
        switch item {
        case let .song(song):
            Task { await self.playerService.playWithRadio(song: song) }
        case let .artist(artist):
            self.navigationPath.append(artist)
        case let .playlist(playlist):
            self.navigationPath.append(playlist)
        case let .album(album):
            self.navigationPath.append(
                Playlist(
                    id: album.id,
                    title: album.title,
                    description: nil,
                    thumbnailURL: album.thumbnailURL,
                    trackCount: album.trackCount,
                    author: album.artistsDisplay
                )
            )
        }
    }

    /// The most recently played songs, one row per video, for the empty page's shelf.
    private var recentlyPlayedItems: [HomeSectionItem]? {
        guard let viewModel = self.recentHistoryViewModel, viewModel.loadingState == .loaded else {
            return nil
        }

        var seen = Set<String>()
        var items: [HomeSectionItem] = []
        for section in viewModel.sections {
            for item in section.items {
                guard case .song = item, seen.insert(item.id).inserted else { continue }
                items.append(item)
                if items.count == 8 {
                    return items
                }
            }
        }
        return items
    }

    private func loadRecentHistoryIfNeeded() async {
        guard self.recentHistoryViewModel == nil else { return }
        let viewModel = HistoryViewModel(client: self.viewModel.client)
        self.recentHistoryViewModel = viewModel
        await viewModel.load()
    }

    private var noResultsView: some View {
        ContentUnavailableView {
            Label(String(localized: "No results found"), systemImage: "magnifyingglass")
        } description: {
            Text("Try a different search, or widen the filter.")
        } actions: {
            if self.viewModel.selectedFilter != .all {
                Button(String(localized: "Show All Results")) {
                    self.viewModel.selectedFilter = .all
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var resultsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // YouTube Music's own page opens with a top-result card; the rows below it start
                    // after the card, so the result the card shows is not drawn twice.
                    if self.viewModel.selectedFilter == .all,
                       let topResult = SearchResultRanker.topResult(self.viewModel.results)
                    {
                        SearchTopResultCard(
                            topResult: topResult,
                            onSelect: { self.handleItemTap($0) },
                            onQuickAction: { item, action in
                                self.handleQuickAction(action, on: item)
                            }
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 10)
                        .padding(.bottom, 14)
                    }

                    ForEach(self.viewModel.filteredItems) { item in
                        self.resultRow(item, isSelected: item.id == self.selectedResultID)
                            .id(item.id)
                        Divider()
                            .padding(.leading, 72)
                    }

                    // Load more indicator / button
                    if self.viewModel.hasMoreResults {
                        self.loadMoreView
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: self.selectedResultID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    /// Load more view that triggers pagination when visible.
    private var loadMoreView: some View {
        Group {
            if self.viewModel.loadingState == .loadingMore {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading more...", comment: "Shown while loading more search results")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                Button {
                    Task { await self.viewModel.loadMore() }
                } label: {
                    Text("Load More", comment: "Button to load more search results")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.plain)
                .onAppear {
                    // Auto-load more when this view appears (infinite scroll)
                    Task { await self.viewModel.loadMore() }
                }
            }
        }
    }

    private func resultRow(_ item: SearchResultItem, isSelected: Bool) -> some View {
        Button {
            self.handleItemTap(item)
        } label: {
            HStack(spacing: 12) {
                // Thumbnail
                CachedAsyncImage(url: item.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: item.systemImage)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 48, height: 48)
                .clipShape(.rect(cornerRadius: item.isArtist ? 24 : 6))

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 14))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(item.resultType)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        if let subtitle = item.subtitle {
                            Text("•")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)

                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                // Play indicator for songs
                if item.videoId != nil {
                    Image(systemName: "play.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.interactiveRow(cornerRadius: 6))
        .contextMenu {
            self.contextMenuItems(for: item)
        }
    }

    @ViewBuilder
    private func contextMenuItems(for item: SearchResultItem) -> some View {
        switch item {
        case let .song(song):
            self.songContextMenu(song)
        case let .album(album):
            self.albumContextMenu(album)
        case let .artist(artist):
            self.artistContextMenu(artist)
        case let .playlist(playlist):
            self.playlistContextMenu(playlist)
        case let .podcastShow(show):
            self.podcastShowContextMenu(show)
        }
    }

    @ViewBuilder
    private func songContextMenu(_ song: Song) -> some View {
        Button {
            Task { await self.playerService.playWithRadio(song: song) }
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Divider()

        LikeDislikeContextMenu(song: song, likeStatusManager: self.likeStatusManager)

        Divider()

        StartRadioContextMenu.menuItem(for: song, playerService: self.playerService)

        Divider()

        Button {
            SongActionsHelper.addToLibrary(song, playerService: self.playerService)
        } label: {
            Label("Add to Library", systemImage: "plus.circle")
        }

        Divider()

        ShareContextMenu.menuItem(for: song)

        Divider()

        AddToQueueContextMenu(song: song, playerService: self.playerService)

        Divider()

        AddToPlaylistContextMenu(
            song: song,
            client: self.viewModel.client,
            libraryViewModel: self.libraryViewModel
        )

        Divider()

        // Go to Artist - show first artist with valid ID
        if let artist = song.artists.first(where: { $0.hasNavigableId }) {
            NavigationLink(value: artist) {
                Label("Go to Artist", systemImage: "person")
            }
        }

        // Go to Album - show if album has valid browse ID
        if let album = song.album, album.hasNavigableId {
            let playlist = Playlist(
                id: album.id,
                title: album.title,
                description: nil,
                thumbnailURL: album.thumbnailURL ?? song.thumbnailURL,
                trackCount: album.trackCount,
                author: album.artistsDisplay
            )
            NavigationLink(value: playlist) {
                Label("Go to Album", systemImage: "square.stack")
            }
        }
    }

    @ViewBuilder
    private func albumContextMenu(_ album: Album) -> some View {
        Button {
            let playlist = Playlist(
                id: album.id,
                title: album.title,
                description: nil,
                thumbnailURL: album.thumbnailURL,
                trackCount: album.trackCount,
                author: album.artistsDisplay
            )
            self.navigationPath.append(playlist)
        } label: {
            Label("View Album", systemImage: "square.stack")
        }

        Divider()

        // Play / Play Next / Add to Queue for albums
        Button {
            SongActionsHelper.playAlbum(
                album,
                client: self.viewModel.client,
                playerService: self.playerService
            )
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            SongActionsHelper.addAlbumToQueueNext(
                album,
                client: self.viewModel.client,
                playerService: self.playerService
            )
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button {
            SongActionsHelper.addAlbumToQueueLast(
                album,
                client: self.viewModel.client,
                playerService: self.playerService
            )
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }

        Divider()

        ShareContextMenu.menuItem(for: album)
    }

    @ViewBuilder
    private func artistContextMenu(_ artist: Artist) -> some View {
        Button {
            self.navigationPath.append(artist)
        } label: {
            Label("View Artist", systemImage: "person")
        }

        Divider()

        ShareContextMenu.menuItem(for: artist)
    }

    @ViewBuilder
    private func playlistContextMenu(_ playlist: Playlist) -> some View {
        // Offered only for a playlist the library can hold: the write sends the playlist's ID as a
        // `playlistId`, so a mix or radio (`RD…`) that search can list has no membership to add (see
        // `Playlist.isLibraryHoldable(id:)`). An album's own context menu already offers no library action.
        if playlist.supportsLibraryMembership {
            Button {
                Task {
                    await SongActionsHelper.addPlaylistToLibrary(
                        playlist,
                        client: self.viewModel.client,
                        libraryViewModel: self.libraryViewModel
                    )
                }
            } label: {
                Label("Add to Library", systemImage: "plus.circle")
            }

            Divider()
        }

        Divider()

        ShareContextMenu.menuItem(for: playlist)

        Divider()

        Button {
            self.navigationPath.append(playlist)
        } label: {
            Label("View Playlist", systemImage: "music.note.list")
        }
    }

    @ViewBuilder
    private func podcastShowContextMenu(_ show: PodcastShow) -> some View {
        Button {
            self.navigationPath.append(show)
        } label: {
            Label("View Podcast", systemImage: "mic.fill")
        }

    }

    // MARK: - Helpers

    /// The row Return should open: the highlighted result, when the arrow keys have moved into the list.
    private var selectedResult: SearchResultItem? {
        guard let selectedID = self.selectedResultID else { return nil }
        return self.viewModel.filteredItems.first { $0.id == selectedID }
    }

    /// Moves the keyboard cursor through the results.
    ///
    /// Clearing it at the top hands the arrow keys back to the field, so typing and Escape keep
    /// working after the reader walked down into the list and back up.
    private func moveResultSelection(by offset: Int) {
        let items = self.viewModel.filteredItems
        guard !items.isEmpty else { return }

        guard let selectedID = self.selectedResultID,
              let index = items.firstIndex(where: { $0.id == selectedID })
        else {
            self.selectedResultID = offset > 0 ? items.first?.id : nil
            return
        }

        let next = index + offset
        guard next >= 0 else {
            self.selectedResultID = nil
            return
        }
        self.selectedResultID = items[min(next, items.count - 1)].id
    }

    /// Plays the card's item without opening it: a song plays itself, an album or playlist loads its
    /// tracks first, the way its own page's Play and Shuffle buttons do.
    private func handleQuickAction(_ action: SearchTopResultCard.QuickAction, on item: SearchResultItem) {
        switch item {
        case let .song(song):
            Task {
                await self.playerService.playWithRadio(song: song)
            }
        case let .album(album):
            SongActionsHelper.playAlbum(
                album,
                client: self.viewModel.client,
                playerService: self.playerService,
                shuffled: action == .shuffle
            )
        case let .playlist(playlist):
            SongActionsHelper.playPlaylist(
                playlist,
                client: self.viewModel.client,
                playerService: self.playerService,
                shuffled: action == .shuffle
            )
        case let .artist(artist):
            switch action {
            case .shuffle:
                SongActionsHelper.shuffleArtist(
                    artist,
                    client: self.viewModel.client,
                    playerService: self.playerService
                )
            case .mix:
                SongActionsHelper.playArtistMix(
                    artist,
                    client: self.viewModel.client,
                    playerService: self.playerService
                )
            case .play:
                break
            }
        case .podcastShow:
            break
        }
    }

    private func handleItemTap(_ item: SearchResultItem) {
        switch item {
        case let .song(song):
            // Play the song and fetch similar songs (radio queue) in the background
            Task {
                await self.playerService.playWithRadio(song: song)
            }
        case let .artist(artist):
            self.navigationPath.append(artist)
        case let .album(album):
            // Navigate as playlist for now
            let playlist = Playlist(
                id: album.id,
                title: album.title,
                description: nil,
                thumbnailURL: album.thumbnailURL,
                trackCount: album.trackCount,
                author: album.artistsDisplay
            )
            self.navigationPath.append(playlist)
        case let .playlist(playlist):
            self.navigationPath.append(playlist)
        case let .podcastShow(show):
            self.navigationPath.append(show)
        }
    }
}

extension SearchResultItem {
    var isArtist: Bool {
        if case .artist = self { return true }
        return false
    }
}

#Preview {
    @Previewable @State var focusTrigger = false
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    SearchView(viewModel: SearchViewModel(client: client), focusTrigger: $focusTrigger)
        .environment(PlayerService())
}
