import SwiftUI

/// Home view displaying personalized content sections.
@available(macOS 26.0, *)
struct HomeView: View {
    @State var viewModel: HomeViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(SongLikeStatusManager.self) private var likeStatusManager
    @Environment(LibraryViewModel.self) private var libraryViewModel: LibraryViewModel?
    @State private var navigationPath = NavigationPath()
    @State private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        PageNavigationStack(id: "home", path: self.$navigationPath) {
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
                        HomeLoadingView()
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
            .pageTitle(id: "home", title: String(localized: "Home"))
            .navigationDestinations(client: self.viewModel.client, artistPath: self.$navigationPath)
            // The bar is attached *inside* the stack, to the page the stack shows.
            //
            // Applied outside it, the bar belongs to the stack's container instead: it survives a push,
            // and the pushed page — every destination has a bar of its own — then draws a second one
            // directly above it. Measured in a reproduction: with the inset inside the stack a push
            // renders one bar, with it outside, two. See `PlayerBar`.
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
                // Favorites section (hidden when empty)
                if self.favoritesManager.isVisible {
                    FavoritesSection(onNavigate: { destination in
                        if let playlist = destination as? Playlist {
                            self.navigationPath.append(playlist)
                        } else if let artist = destination as? Artist {
                            self.navigationPath.append(artist)
                        } else if let podcastShow = destination as? PodcastShow {
                            self.navigationPath.append(podcastShow)
                        }
                    })
                    .staggeredAppearance(index: 0)
                }

                // API sections - use stable id without array enumeration
                ForEach(self.viewModel.sections) { section in
                    self.sectionView(section)
                        .task {
                            await self.prefetchImagesAsync(for: section)
                        }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private func sectionView(_ section: HomeSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.title2)
                .fontWeight(.semibold)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    // Use stable ID from items, avoid enumeration for non-chart sections
                    if section.isChart {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                            HomeSectionItemCard(item: item, rank: index + 1) {
                                self.playItem(item, in: section, at: index)
                            }
                            .contextMenu {
                                HomeCardMenuContent(
                                    item: item,
                                    client: self.viewModel.client,
                                    favoritesManager: self.favoritesManager,
                                    likeStatusManager: self.likeStatusManager,
                                    playerService: self.playerService,
                                    libraryViewModel: self.libraryViewModel
                                )
                            }
                        }
                    } else {
                        ForEach(section.items) { item in
                            HomeSectionItemCard(item: item) {
                                self.playItem(item, in: section, at: 0)
                            }
                            .contextMenu {
                                HomeCardMenuContent(
                                    item: item,
                                    client: self.viewModel.client,
                                    favoritesManager: self.favoritesManager,
                                    likeStatusManager: self.likeStatusManager,
                                    playerService: self.playerService,
                                    libraryViewModel: self.libraryViewModel
                                )
                            }
                        }
                    }
                }
            }
            .scrollClipDisabled()
            .horizontalRowEdgeFade()
        }
    }

    // MARK: - Image Prefetching

    private static let thumbnailDisplaySize = CGSize(width: 160, height: 160)

    private func prefetchImagesAsync(for section: HomeSection) async {
        // Early exit if task is cancelled
        guard !Task.isCancelled else { return }

        let urls = section.items.prefix(10).compactMap { $0.thumbnailURL?.highQualityThumbnailURL }
        guard !urls.isEmpty else { return }

        await ImageCache.shared.prefetch(
            urls: urls,
            targetSize: Self.thumbnailDisplaySize,
            maxConcurrent: 4
        )
    }

    // MARK: - Actions

    private func playItem(_ item: HomeSectionItem, in _: HomeSection, at _: Int) {
        switch item {
        case let .song(song):
            // Play the song and fetch similar songs (radio queue) in the background
            Task {
                await self.playerService.playWithRadio(song: song)
            }
        case let .playlist(playlist):
            // Navigate to playlist detail
            self.navigationPath.append(playlist)
        case let .album(album):
            // For now, we'll create a playlist-like navigation for albums
            // In a full implementation, we'd have an AlbumDetailView
            let playlist = Playlist(
                id: album.id,
                title: album.title,
                description: nil,
                thumbnailURL: album.thumbnailURL,
                trackCount: album.trackCount,
                author: album.artistsDisplay
            )
            self.navigationPath.append(playlist)
        case let .artist(artist):
            // Navigate to artist detail
            self.navigationPath.append(artist)
        }
    }
}

// MARK: - HomeCardMenuContent

/// The card's context menu, as its own view.
///
/// Dedicated for the same reason as `PlaylistTrackMenuContent`: the favorites and like lookups
/// happen inside *this* view's body, which SwiftUI evaluates when the menu opens. Evaluating them in
/// `HomeView`'s body subscribed the whole page to `FavoritesManager`, so pinning a favorite anywhere
/// rebuilt every visible card.
@available(macOS 26.0, *)
struct HomeCardMenuContent: View {
    let item: HomeSectionItem
    let client: any YTMusicClientProtocol
    let favoritesManager: FavoritesManager
    let likeStatusManager: SongLikeStatusManager
    let playerService: PlayerService
    let libraryViewModel: LibraryViewModel?

    var body: some View {
        switch self.item {
        case let .song(song):
            Button {
                Task { await self.playerService.play(song: song) }
            } label: {
                Label("Play", systemImage: "play.fill")
            }

            Divider()

            FavoritesContextMenu.menuItem(for: song, manager: self.favoritesManager)

            Divider()

            LikeDislikeContextMenu(song: song, likeStatusManager: self.likeStatusManager)

            Divider()

            StartRadioContextMenu.menuItem(for: song, playerService: self.playerService)

            Divider()

            ShareContextMenu.menuItem(for: song)

            Divider()

            AddToQueueContextMenu(song: song, playerService: self.playerService)

            Divider()

            AddToPlaylistContextMenu(
                song: song,
                client: self.client,
                libraryViewModel: self.libraryViewModel
            )

            Divider()

            if let artist = song.artists.first(where: { $0.hasNavigableId }) {
                NavigationLink(value: artist) {
                    Label("Go to Artist", systemImage: "person")
                }
            }

            if let album = song.album, album.hasNavigableId {
                NavigationLink(value: Self.playlist(for: album, thumbnailURL: album.thumbnailURL ?? song.thumbnailURL)) {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }

        case let .album(album):
            NavigationLink(value: Self.playlist(for: album, thumbnailURL: album.thumbnailURL)) {
                Label("View Album", systemImage: "square.stack")
            }

            Divider()

            // Play / Play Next / Add to Queue for albums
            Button {
                SongActionsHelper.playAlbum(
                    album,
                    client: self.client,
                    playerService: self.playerService
                )
            } label: {
                Label("Play", systemImage: "play.fill")
            }

            Button {
                SongActionsHelper.addAlbumToQueueNext(
                    album,
                    client: self.client,
                    playerService: self.playerService
                )
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }

            Button {
                SongActionsHelper.addAlbumToQueueLast(
                    album,
                    client: self.client,
                    playerService: self.playerService
                )
            } label: {
                Label("Add to Queue", systemImage: "text.append")
            }

            Divider()

            FavoritesContextMenu.menuItem(for: album, manager: self.favoritesManager)

            Divider()

            ShareContextMenu.menuItem(for: album)

        case let .playlist(playlist):
            NavigationLink(value: playlist) {
                Label("View Playlist", systemImage: "music.note.list")
            }

            Divider()

            FavoritesContextMenu.menuItem(for: playlist, manager: self.favoritesManager)

            Divider()

            ShareContextMenu.menuItem(for: playlist)

        case let .artist(artist):
            NavigationLink(value: artist) {
                Label("View Artist", systemImage: "person")
            }

            Divider()

            FavoritesContextMenu.menuItem(for: artist, manager: self.favoritesManager)

            ShareContextMenu.menuItem(for: artist)
        }
    }

    private static func playlist(for album: Album, thumbnailURL: URL?) -> Playlist {
        Playlist(
            id: album.id,
            title: album.title,
            description: nil,
            thumbnailURL: thumbnailURL,
            trackCount: album.trackCount,
            author: album.artistsDisplay
        )
    }
}

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    HomeView(viewModel: HomeViewModel(client: client))
        .environment(PlayerService())
        .environment(FavoritesManager.shared)
}
