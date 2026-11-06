import SwiftUI

/// Home view displaying personalized content sections.
@available(macOS 26.0, *)
struct HomeView: View {
    @State var viewModel: HomeViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(SongLikeStatusManager.self) private var likeStatusManager
    @Environment(LibraryViewModel.self) private var libraryViewModel: LibraryViewModel?
    @Environment(AccountService.self) private var accountService: AccountService?
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
        // The feed is the account's, so the page tells its model which account it is showing. The model
        // shows the skeleton until that account's fresh feed arrives.
        .onAppear {
            let accountID = self.accountService?.currentAccount?.id
            Task {
                await self.viewModel.activate(accountID: accountID)
            }
        }
        .onChange(of: self.accountService?.currentAccount?.id) { _, accountID in
            Task {
                await self.viewModel.activate(accountID: accountID)
            }
        }
        .refreshable {
            await self.viewModel.refresh()
        }
    }

    // MARK: - Views

    private var contentView: some View {
        HomeFeedCollectionView(
            sections: self.viewModel.sections,
            client: self.viewModel.client,
            playerService: self.playerService,
            likeStatusManager: self.likeStatusManager,
            libraryViewModel: self.libraryViewModel,
            onSelect: { item in self.playItem(item) }
        )
    }

    // MARK: - Actions

    private func playItem(_ item: HomeSectionItem) {
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
/// Dedicated for the same reason as `PlaylistTrackMenuContent`: the like lookup happens inside *this*
/// view's body, which SwiftUI evaluates when the menu opens. Evaluating it in `HomeView`'s body
/// subscribed the whole page to `SongLikeStatusManager`, so rating a song anywhere rebuilt every
/// visible card.
@available(macOS 26.0, *)
struct HomeCardMenuContent: View {
    let item: HomeSectionItem
    let client: any YTMusicClientProtocol
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

            ShareContextMenu.menuItem(for: album)

        case let .playlist(playlist):
            NavigationLink(value: playlist) {
                Label("View Playlist", systemImage: "music.note.list")
            }

            Divider()

            ShareContextMenu.menuItem(for: playlist)

        case let .artist(artist):
            NavigationLink(value: artist) {
                Label("View Artist", systemImage: "person")
            }

            Divider()

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
}
