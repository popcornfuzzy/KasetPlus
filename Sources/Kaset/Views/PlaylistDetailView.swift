import FoundationModels
import SwiftUI

// MARK: - PlaylistDetailView

/// Detail view for a playlist showing its tracks.
@available(macOS 26.0, *)
struct PlaylistDetailView: View {
    let playlist: Playlist
    @State var viewModel: PlaylistDetailViewModel

    /// Pushes an artist page onto the stack this page is shown in. Handed in by whoever registered the
    /// page's navigation destinations, because a pushed page cannot reach the enclosing stack's path
    /// itself and must not declare a second `navigationDestination` (see `contentView(_:)`).
    let onNavigateToArtist: (Artist) -> Void
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(SongLikeStatusManager.self) private var likeStatusManager
    @Environment(AccountService.self) private var accountService
    @Environment(LibraryViewModel.self) private var libraryViewModel: LibraryViewModel?
    @Environment(\.dismiss) private var dismiss

    /// Tracks whether this playlist has been added to library in this session.
    @State private var isAddedToLibrary: Bool = false

    /// Whether the refine playlist sheet is visible.
    @State private var showRefineSheet: Bool = false

    /// AI-generated playlist changes.
    @State private var playlistChanges: PlaylistChanges?

    /// Partial playlist changes during streaming.
    @State private var partialChanges: PlaylistChanges.PartiallyGenerated?

    /// Whether AI is processing the refine request.
    @State private var isRefining: Bool = false

    /// Error message from refine operation.
    @State private var refineError: String?

    /// Whether playlist rename popover is visible.
    @State private var showRenamePlaylistPopover: Bool = false

    /// Whether delete confirmation is visible.
    @State private var showDeletePlaylistAlert: Bool = false

    /// Draft title for rename action.
    @State private var playlistTitleDraft: String = ""

    /// Whether a rename request is currently in progress.
    @State private var isRenamingPlaylist: Bool = false

    /// Whether a delete request is currently in progress.
    @State private var isDeletingPlaylist: Bool = false

    /// Error message for playlist management actions.
    @State private var playlistActionError: String?

    /// Whether the track list is scrolling. Used to suspend row hover highlighting so rows
    /// passing under a stationary pointer don't animate their background mid-flick.
    @State private var isScrolling: Bool = false

    /// Scroll distance from the bottom, in points, at which the next page is requested.
    /// Requesting a page this early keeps the fetch and its spinner below the visible
    /// window, so scrolling never waits on the network.
    private static let paginationThreshold: CGFloat = 1200

    /// Bucket size for the near-bottom check. Bucketing instead of a plain boolean means a
    /// short page that still leaves the list near its bottom triggers on the next nudge.
    private static let paginationBucket: CGFloat = 200

    /// How many upcoming rows' artwork to warm in the image cache.
    private static let thumbnailPrefetchWindow = 60

    /// Edge length of the header thumbnail. It also sets the height of the header's info column, so
    /// the action row lines up with the thumbnail's bottom edge.
    private static let artworkSize: CGFloat = 180

    /// Height of every control in the header's action row.
    ///
    /// A `.controlSize(.large)` glass control is not one height: measured on macOS 26, a labelled glass
    /// button comes out 28 pt tall while an icon-only one is 26, so the row's icon buttons sat 2 pt
    /// short of the Play button beside them. The row fixes every control to the labelled height rather
    /// than mixing the two (see ADR-0033 and `HeaderActionRowTests`).
    private static let actionRowControlHeight: CGFloat = 28

    /// The size of the overflow control, which the row draws itself.
    ///
    /// Measured in the running app, a `.controlSize(.large)` glyph glass button comes out 46 by 26 pt.
    /// A `Menu` cannot be given that size by a menu or button style: left alone, macOS draws its own
    /// pull-down chrome over the row (a flat pill, 61.5 pt wide, with a chevron), and under
    /// `.menuStyle(.button)` that indicator costs another 27.5 pt (74.5 against 47 without) while the
    /// row's `.buttonStyle(.glass)` still does not reach the control. So the overflow control is plain
    /// and states its own size and material — see `moreActionsMenu`. `HeaderActionRowTests` holds it to
    /// the size the glyph buttons beside it come out at.
    private static let overflowControlSize = CGSize(width: 46, height: 26)

    /// The shapes the action row can take, widest first.
    ///
    /// The two widest name their actions; every shape after them shows the same actions as glyphs. The
    /// list is one source of both the row that is drawn and the widths it is measured as, so the ladder
    /// cannot drift from what the row can show (`HeaderActionRowTests` walks it).
    private static let shapeLadder: [HeaderRowShape] = [
        HeaderRowShape(actions: [.radio, .playNext, .addToQueue, .library], showsTitles: true),
        HeaderRowShape(actions: [.radio, .playNext, .addToQueue], showsTitles: true),
        HeaderRowShape(actions: [.radio, .playNext, .addToQueue, .library, .refine], showsTitles: false),
        HeaderRowShape(actions: [.radio, .playNext, .addToQueue, .library], showsTitles: false),
        HeaderRowShape(actions: [.radio, .playNext, .addToQueue], showsTitles: false),
        HeaderRowShape(actions: [.radio, .playNext], showsTitles: false),
        HeaderRowShape(actions: [.radio], showsTitles: false),
        HeaderRowShape(actions: [], showsTitles: false),
    ]

    /// One shape of the action row: which of the page's secondary actions it renders inline, and whether
    /// it gives them their names.
    private struct HeaderRowShape {
        let actions: HeaderAction
        let showsTitles: Bool
    }

    /// The width the header offers the action row, and the width each shape of the ladder came out at,
    /// both measured by the row itself. `shapeWidths` starts empty: until a shape has been measured the
    /// row shows the narrowest one, which is the only shape that cannot overflow a row it has not been
    /// measured against.
    @State private var rowAvailableWidth: CGFloat = 0
    @State private var shapeWidths: [CGFloat] = Array(repeating: 0, count: PlaylistDetailView.shapeLadder.count)
    @State private var rowShapeIndex: Int = PlaylistDetailView.shapeLadder.count - 1

    /// Every ID the library could know this page by. Until the detail's header has loaded there is nothing
    /// to derive, and the page's own ID stands in — which is what the playlist case wants anyway.
    private var libraryMatchIds: [String] {
        self.viewModel.playlistDetail?.libraryMatchIds.sorted() ?? [self.playlist.id]
    }

    /// Computed property to check if playlist is in library.
    private var isInLibrary: Bool {
        self.libraryViewModel?.isInLibrary(anyOf: self.libraryMatchIds) ?? false
    }

    /// The ID a library write goes to, or `nil` when this page has nothing the library can be told.
    ///
    /// The detail's own `libraryId` first — a playlist's own ID, or an album's `OLAK5uy_…` audio playlist,
    /// named by the page's own save action or its radio target. Failing that, the ID the library *already*
    /// lists this page under, which is what lets a radio playlist the library's listing carries be dropped
    /// again. An album's page ID is refused as a target in both cases: `like/like` answers `MPREb_…` with
    /// `HTTP 404`, so writing it is the dead control this action used to be (see ADR-0033).
    private var libraryWriteId: String? {
        if let libraryId = self.viewModel.playlistDetail?.libraryId {
            return libraryId
        }

        guard let storedId = self.libraryViewModel?.storedLibraryId(matching: self.libraryMatchIds),
              !Playlist.isAlbumPageId(storedId)
        else {
            return nil
        }

        return storedId
    }

    /// The page as the library addresses it, which is not always as the page addresses itself.
    private var libraryPlaylist: Playlist {
        guard let writeId = self.libraryWriteId, writeId != self.playlist.id else {
            return self.playlist
        }
        return Playlist(
            id: writeId,
            title: self.playlist.title,
            description: self.playlist.description,
            thumbnailURL: self.playlist.thumbnailURL,
            trackCount: self.playlist.trackCount,
            author: self.playlist.author
        )
    }

    private let logger = DiagnosticsLogger.ai

    init(
        playlist: Playlist,
        viewModel: PlaylistDetailViewModel,
        onNavigateToArtist: @escaping (Artist) -> Void
    ) {
        self.playlist = playlist
        _viewModel = State(initialValue: viewModel)
        self.onNavigateToArtist = onNavigateToArtist
    }

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView(String(localized: "Loading playlist..."))
            case .loaded, .loadingMore:
                if let detail = viewModel.playlistDetail {
                    self.contentView(detail)
                } else {
                    ErrorView(title: String(localized: "Unable to load playlist"), message: String(localized: "Playlist not found")) {
                        Task { await self.viewModel.load() }
                    }
                }
            case let .error(error):
                ErrorView(error: error) {
                    Task { await self.viewModel.load() }
                }
            }
        }
        .accentBackground(from: self.viewModel.playlistDetail?.thumbnailURL?.highQualityThumbnailURL)
        .pageTitle(id: "playlist-\(self.playlist.id)", title: self.viewModel.playlistDetail?.title ?? self.playlist.title)
        // The controls are real toolbar items now: the window shell's inspector tracking separator bounds
        // the page's region by the column's divider, so they stop where the column begins instead of
        // landing on top of it. This page publishes them; see `PageToolbarContribution`.
        .pageToolbar(id: "playlist-\(self.playlist.id)") {
            PlaylistToolbarControls(
                viewModel: self.viewModel,
                library: self.libraryViewModel
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .error = self.viewModel.loadingState {} else {
                PlayerBar()
            }
        }
        // Keyed by the active account: the tracks here are that account's list (Liked Music is the
        // account's liked songs, a playlist is the account's copy), so switching channels has to
        // reload the page instead of leaving the previous channel's rows — and their like state —
        // on screen. See `PlaylistDetailViewModel.loadIfAccountChanged`.
        .task(id: self.accountService.currentAccount?.id) {
            // The header's library control states membership, which is read off the window's library
            // snapshot — and a window that has never shown the Library has none, so the control read "Add
            // to Library" on pages the account already owned. The two loads go together: the page never
            // waits on the library.
            await withTaskGroup(of: Void.self) { group in
                if let libraryViewModel = self.libraryViewModel {
                    group.addTask { await libraryViewModel.loadIfNeeded() }
                }
                group.addTask {
                    await self.viewModel.loadIfAccountChanged(self.accountService.currentAccount?.id)
                }
            }
        }
        .refreshable {
            await self.viewModel.performRefresh(library: self.libraryViewModel)
        }
        .sheet(isPresented: self.$showRefineSheet) {
            if let detail = viewModel.playlistDetail {
                RefinePlaylistSheet(
                    tracks: detail.tracks,
                    isProcessing: self.$isRefining,
                    changes: self.$playlistChanges,
                    partialChanges: self.$partialChanges,
                    errorMessage: self.$refineError,
                    onRefine: { prompt in
                        await self.refinePlaylist(tracks: detail.tracks, prompt: prompt)
                    },
                    onApply: {
                        // Playlist modification via API not yet implemented
                        // For now, just close the sheet
                        self.showRefineSheet = false
                    }
                )
            }
        }
    }

    // MARK: - Views

    /// The tracks are rendered by an AppKit-backed `List`, whose rows are laid out and reused by
    /// NSTableView. A `ScrollView` + `LazyVStack` re-measures and re-renders the whole realised page
    /// on every scroll frame, which made the per-frame cost proportional to the rows' view-tree size
    /// — see ADR-0014 for the measurements.
    ///
    /// The header is the list's **first row**: it scrolls away with the tracks, and the table measures
    /// it, so the page never has to guess its height (ADR-0023).
    ///
    /// It is deliberately not a section header. On macOS a `List`'s section header is a floating group
    /// row: it parks itself on top of the tracks for the rest of the scroll, and a navigation started
    /// from it still selects it, so the sticky band and the highlight come together.
    ///
    /// Nothing in the header navigates on its own either. A `NavigationLink` (and a `Menu`, which hands
    /// its items the same activation) inside a row makes the table treat the row as the navigation
    /// source: it selects the row, paints that selection across the whole header — accent while the
    /// window is key, gray while it is not — and keeps the row's activation, so a second click on the
    /// same control is swallowed. `.listRowBackground(Color.clear)`, `.borderless`, `.selectionDisabled`
    /// and rebuilding the row on return all left it in place. The credited artists are plain buttons that
    /// push the artist onto the stack's own path instead; see `artistCredit(_:)` and ADR-0023.
    private func contentView(_ detail: PlaylistDetail) -> some View {
        let tracks = self.visibleTracks(detail)

        return VStack(spacing: 0) {
            self.withScrollObservers(
                List {
                    // The header is a row, so the table lays it out and the page never has to guess
                    // how tall it is; being a row is also what lets it scroll away with the tracks.
                    self.headerView(detail)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 24, bottom: 24, trailing: 24))
                        .listRowBackground(Color.clear)

                    Divider()
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                        .listRowBackground(Color.clear)

                    if !self.viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.searchStatusRow(detail, matchCount: tracks.count)
                    }

                    self.trackRows(detail, tracks: tracks)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .task(id: detail.tracks.count) {
                    await self.prefetchUpcomingThumbnails(for: detail.tracks)
                }
            )
        }
    }

    /// The tracks that match the current query, or every loaded track when there is no query.
    private func visibleTracks(_ detail: PlaylistDetail) -> [Song] {
        let query = self.viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return detail.tracks }

        return detail.tracks.filter { song in
            song.title.localizedCaseInsensitiveContains(query)
                || song.artistsDisplay.localizedCaseInsensitiveContains(query)
                || (song.album?.title.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Status line above the results while a search is running over the whole playlist.
    @ViewBuilder
    private func searchStatusRow(_ detail: PlaylistDetail, matchCount: Int) -> some View {
        Group {
            if self.viewModel.isLoadingAllTracks {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching all songs…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if matchCount == 0 {
                Text("No songs match \u{201C}\(self.viewModel.searchText)\u{201D}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(matchCount) of \(detail.resolvedTrackCount) songs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    /// Paging and hover suppression are attached to whichever scroll container renders the page.
    private func withScrollObservers<V: View>(_ content: V) -> some View {
        content
            .onScrollPhaseChange { _, newPhase, _ in
                // Suspend hover highlighting while rows move under a stationary pointer.
                let isScrolling = newPhase != .idle
                if isScrolling != self.isScrolling {
                    self.isScrolling = isScrolling
                }
            }
            .onScrollGeometryChange(for: Int.self) { geometry in
                // Bucket the remaining scroll distance so the value keeps changing as the user
                // scrolls near the bottom instead of latching true. Paging stays off while a
                // search owns the list, since the search already pulls every page.
                guard self.viewModel.hasMore, self.viewModel.searchText.isEmpty else { return .max }
                let remaining = geometry.contentSize.height
                    - (geometry.contentOffset.y + geometry.containerSize.height)
                guard remaining < Self.paginationThreshold else { return .max }
                return max(0, Int(remaining / Self.paginationBucket))
            } action: { _, bucket in
                guard bucket != .max else { return }
                Task {
                    await self.viewModel.loadMore()
                }
            }
    }

    /// Thumbnail, title and credits in a row, with the action row on the thumbnail's bottom edge.
    ///
    /// The actions are aligned rather than pushed down by a `Spacer` in the info column: everything in
    /// the box is then a definite size, so the row's height is the 180 pt thumbnail plus the insets and
    /// the buttons land on its baseline. A `Spacer` left the header free to absorb the row's height and
    /// the buttons drifted ~140 pt below the credits (see ADR-0023).
    ///
    /// The rename popover and the delete alert hang off the header rather than off the action button
    /// that opens them: `ViewThatFits` measures every shape of the row at once (see `headerActionRow`),
    /// so a presentation attached inside the row would be built once per shape and every copy would
    /// answer the same binding.
    private func headerView(_ detail: PlaylistDetail) -> some View {
        ZStack(alignment: .bottomLeading) {
            HStack(alignment: .top, spacing: 20) {
                // Thumbnail
                CachedAsyncImage(url: detail.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: Self.artworkSize, height: Self.artworkSize)
                .clipShape(.rect(cornerRadius: 8))
                .fadeIn(duration: 0.3)
                .accessibilityIdentifier(AccessibilityID.PlaylistDetail.artwork)

                // Info. Type, title, credits, then the track count and duration — the same order
                // Apple Music's album and playlist headers read in.
                VStack(alignment: .leading, spacing: 8) {
                    Text(detail.isAlbum ? String(localized: "Album") : String(localized: "Playlist"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Text(detail.title)
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)

                    self.creditsView(detail)

                    Text(self.metadataText(for: detail))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.PlaylistDetail.metadata)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            self.headerButtons(detail)
                .padding(.leading, Self.artworkSize + 20)
        }
        .popover(isPresented: self.$showRenamePlaylistPopover, arrowEdge: .top) {
            self.renamePlaylistPopover
        }
        .alert("Delete Playlist?", isPresented: self.$showDeletePlaylistAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    await self.deletePlaylist()
                }
            }
            .disabled(self.isDeletingPlaylist)
        } message: {
            Text("This removes the playlist from YouTube Music. This action cannot be undone.")
        }
    }

    private func makeFallbackAlbum(from detail: PlaylistDetail) -> Album {
        Album(
            id: detail.id,
            title: detail.title,
            // Prefer the credited artists so queued songs keep their channel links.
            artists: detail.artists.isEmpty
                ? detail.author.map { [Artist(id: "unknown", name: $0)] }
                : detail.artists,
            thumbnailURL: detail.thumbnailURL,
            year: nil,
            trackCount: detail.trackCount ?? detail.tracks.count
        )
    }

    /// The playlist's creators or the album's artists, on one line: semibold names, secondary
    /// separators. Every name that carries a channel ID is its own control, so an album crediting
    /// several artists opens the one that was clicked — the row's activation, which handed a single
    /// click to every link in the row and always pushed the last of them, is no longer involved.
    ///
    /// A header that exposed no artists at all falls back to the author string.
    @ViewBuilder
    private func creditsView(_ detail: PlaylistDetail) -> some View {
        if detail.artists.isEmpty {
            if let author = detail.author, !author.isEmpty {
                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 0) {
                ForEach(Array(detail.artists.enumerated()), id: \.element.id) { index, artist in
                    if index > 0 {
                        Text(verbatim: ", ")
                            .foregroundStyle(.secondary)
                    }

                    self.artistCredit(artist)
                }
            }
            .font(.subheadline)
        }
    }

    /// A credited artist that opens its page on click.
    ///
    /// A button, not a `NavigationLink`: the credit lives in the header row, and a link in a row makes
    /// the table select that row — painting its highlight over the header and swallowing the row's next
    /// click — as well as handing one click to every link the row contains. Pushing through the stack's
    /// own path, which the page is handed as `onNavigateToArtist`, is the only navigation that does
    /// neither. Names without a channel ID stay plain text.
    ///
    /// The page must not declare its own `navigationDestination` instead: `PlaylistDetailView` is itself
    /// a destination, and a second destination on the same stack re-lays out the page in a loop and
    /// freezes the app (ADR-0023).
    ///
    /// Kept in sync with `PlaylistArtistNavigationUITests`, which clicks a single credit, presses Back
    /// and clicks it again.
    @ViewBuilder
    private func artistCredit(_ artist: Artist) -> some View {
        if artist.hasNavigableId {
            Button {
                self.onNavigateToArtist(artist)
            } label: {
                Text(artist.name)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.PlaylistDetail.artistCredit(artist.id))
        } else {
            Text(artist.name)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Header Actions

    /// A secondary action the header can offer.
    ///
    /// The row and its overflow menu split one set of these: whichever actions fit beside Play and
    /// Shuffle stay in the row as controls, and the rest move into the menu. Nothing is unreachable at
    /// a narrow width, and nothing sits in a menu while the row has room to show it (ADR-0033).
    struct HeaderAction: OptionSet {
        let rawValue: Int

        static let radio = HeaderAction(rawValue: 1 << 0)
        static let playNext = HeaderAction(rawValue: 1 << 1)
        static let addToQueue = HeaderAction(rawValue: 1 << 2)
        static let library = HeaderAction(rawValue: 1 << 3)
        static let refine = HeaderAction(rawValue: 1 << 4)
    }

    /// The actions this page can offer, in the order the row gives them room.
    ///
    /// Refine is offered only on a machine that can run it. Its control is hidden by
    /// `.requiresIntelligence()` when Apple Intelligence is unavailable, and an action this set
    /// advertises while nothing draws it is an action the row's menu counts as left out of the row —
    /// which is how the Liked Music page, where every other action fits, came to draw a "…" whose only
    /// item was a control that is not on screen.
    private func availableHeaderActions(for detail: PlaylistDetail) -> HeaderAction {
        var actions: HeaderAction = [.playNext, .addToQueue]
        if self.offersLibraryAction(for: detail) {
            actions.insert(.library)
        }
        if detail.mixPlaylistId != nil {
            actions.insert(.radio)
        }
        if !detail.isAlbum, FoundationModelsService.shared.isAvailable {
            actions.insert(.refine)
        }
        return actions
    }

    /// Whether this page is offered the library action at all.
    ///
    /// The action is a `like/like` write with an ID as a `playlistId` (`YTMusicClient.subscribeToPlaylist`),
    /// so the page needs an ID the library accepts: a playlist's own ID, or an album's `OLAK5uy_…` audio
    /// playlist (`PlaylistDetail.libraryId`), or — for a page the library already holds, whose control is
    /// then "Remove from Library" — the ID the library lists it under. A page with none of those is not
    /// offered the action: a generated mix (`RD…`), Liked Music, and an album whose header named no target.
    ///
    /// Liked Music is refused first: its ID can appear in the library listing without there being a
    /// membership behind it, and "Remove from Library" beside the library's own list of liked songs reads
    /// as a way to empty it.
    private func offersLibraryAction(for detail: PlaylistDetail) -> Bool {
        if detail.isLikedMusic {
            return false
        }
        return self.libraryWriteId != nil
    }

    /// The header's action row: Play, Shuffle, every action that fits beside them, and one overflow
    /// menu holding the actions that did not.
    ///
    /// The row is one of a fixed ladder of shapes, widest first. It measures every shape offscreen (see
    /// `shapeMeasurers`) and draws the widest one that fits the width the header offers it, so the row
    /// fills up as the window widens and folds back into the menu as it narrows. Each shape ends in the
    /// same "…" menu, and each shape's menu carries exactly the actions its own row left out.
    ///
    /// The shapes are graded rather than just trimmed: the two widest name their actions and every shape
    /// after them shows the same actions as glyphs. Measured, naming a secondary action costs 134 pt of
    /// row where the same action as a glyph costs 53: the four named actions need 735 pt of row, the same
    /// four as glyphs 408, all five as glyphs 465. That grade is what gives the row something to give back
    /// while the window is still wide — without it the ladder's widest shape is 465 pt of a row that is
    /// already 650 pt at the app's narrowest window, so nothing would ever move.
    ///
    /// The shape is measured here rather than left to `ViewThatFits`, which picks a shape by laying all of
    /// them out and keeps its choice to itself — it cannot say what it picked, and every shape it holds
    /// stays in the layout and the accessibility tree. Measuring makes the choice the row's own state, so
    /// only the shape on show is built for display. `HeaderActionRowTests` walks the ladder and holds the two things
    /// the choice relies on: every shape fits the row it is offered, and no shape is wider than the one
    /// above it (a ladder out of order makes the widest fitting shape the wrong one).
    private func headerButtons(_ detail: PlaylistDetail) -> some View {
        let shape = Self.shapeLadder[self.rowShapeIndex]

        return VStack(alignment: .leading, spacing: 10) {
            self.headerActionRow(detail, inline: shape.actions, showsTitles: shape.showsTitles)
                // The frame takes the width it is offered rather than the width its content wants, which is
                // what makes the measurement below the header's width: a shape that outgrows the row cannot
                // widen the row it is being measured against, so the choice cannot chase its own tail.
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .leading) { self.shapeMeasurers(detail) }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    self.setRowWidth(width)
                }

            if let playlistActionError {
                Text(playlistActionError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if let sortOrderError = viewModel.sortOrderError {
                Text(sortOrderError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .task(id: detail.id) { self.logHeaderDecision(detail) }
    }

    /// States what the header resolved, so a control that should not be there can be told apart from one
    /// whose inputs are missing, without a debugger.
    ///
    /// The library control's half: `listing` is what the window's library holds, `matches` the spellings
    /// the page asked it about, and `inLibrary` what the control reads from the two. The row's half:
    /// `management` whether the page is offered Rename and Delete at all, `refine` whether the refine
    /// action is on offer on this machine, and `overflow` one flag per shape of the ladder — `1` where
    /// that shape of the row would draw its "…" menu, widest first. That last one is the whole of "the
    /// '…' shows at some window widths and not others": it is drawn in the shapes that leave an action
    /// over, and a shape that renders everything the page offers has nothing to put in a menu.
    private func logHeaderDecision(_ detail: PlaylistDetail) {
        let listing = self.libraryViewModel?.libraryPlaylistIds ?? []
        let matches = self.libraryMatchIds
        let overlap = matches.filter { match in
            listing.contains { $0.hasPrefix(String(match.prefix(4))) }
        }.count
        let overflow = Self.shapeLadder.indices.map { index in
            self.hasOverflowItems(for: detail, inline: Self.shapeLadder[index].actions) ? "1" : "0"
        }.joined()
        self.logger.info(
            "Header decision: vm=\(self.libraryViewModel != nil, privacy: .public) listing=\(listing.count, privacy: .public) matches=\(matches.map { String($0.prefix(4)) }.joined(separator: "|"), privacy: .public) overlap=\(overlap, privacy: .public) inLibrary=\(self.isInLibrary, privacy: .public) write=\(self.libraryWriteId.map { String($0.prefix(6)) } ?? "none", privacy: .public) album=\(detail.isAlbum, privacy: .public) editable=\(detail.isEditable, privacy: .public) management=\(detail.supportsPlaylistManagement, privacy: .public) refine=\(FoundationModelsService.shared.isAvailable, privacy: .public) actions=\(self.availableHeaderActions(for: detail).rawValue, privacy: .public) overflow=\(overflow, privacy: .public)"
        )
    }

    /// Every shape of the ladder at its own ideal width, laid out invisibly so the row can measure what it
    /// has room for.
    ///
    /// `fixedSize` is what keeps a shape's width its own instead of the row's: the row is wide enough for
    /// the widest shape, and without it every shape would be measured as that one width. The shapes are
    /// hidden and out of the accessibility tree — they are layouts, not controls, and a second copy of
    /// every action in the tree would read as the same action twice.
    private func shapeMeasurers(_ detail: PlaylistDetail) -> some View {
        HStack(spacing: 10) {
            ForEach(Self.shapeLadder.indices, id: \.self) { index in
                let shape = Self.shapeLadder[index]
                self.headerActionRow(detail, inline: shape.actions, showsTitles: shape.showsTitles)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        self.recordShapeWidth(index: index, width: width)
                    }
            }
        }
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The row's width, and the shape that fits it.
    private func setRowWidth(_ width: CGFloat) {
        guard abs(width - self.rowAvailableWidth) > 0.25 else { return }
        self.rowAvailableWidth = width
        self.applyFittingShape()
    }

    /// One shape's measured width, and the shape that fits with it on hand.
    private func recordShapeWidth(index: Int, width: CGFloat) {
        guard self.shapeWidths.indices.contains(index), abs(self.shapeWidths[index] - width) > 0.25 else { return }
        self.shapeWidths[index] = width
        self.applyFittingShape()
    }

    /// Switches the row to the widest shape that fits it.
    ///
    /// The switch is deliberately not animated. Dragged across the rungs, a window resizes continuously, and
    /// interpolating the row through its shapes made every resize a moving picture of buttons growing and
    /// shrinking under the pointer — the row read as squirming rather than as a row that has changed what it
    /// shows. Stated in one step the row still changes shape while the window is dragged; it just does it at
    /// the moment a rung is crossed instead of drawing the way there.
    private func applyFittingShape() {
        let index = Self.fittingShapeIndex(for: self.rowAvailableWidth, widths: self.shapeWidths)
        guard index != self.rowShapeIndex else { return }
        self.rowShapeIndex = index
    }

    /// The widest shape in `widths` that fits `width`, or the narrowest shape when none of them fits or
    /// none has been measured yet.
    ///
    /// The ladder is widest-first, which is what makes the first shape that fits the widest one that does.
    static func fittingShapeIndex(for width: CGFloat, widths: [CGFloat]) -> Int {
        widths.indices.first { index in
            widths[index] > 0 && widths[index] <= width
        } ?? widths.count - 1
    }

    /// One shape of the action row: the primary controls, the requested actions this page has, and a
    /// menu for the rest.
    private func headerActionRow(
        _ detail: PlaylistDetail,
        inline requested: HeaderAction,
        showsTitles: Bool = false
    ) -> some View {
        let inline = self.availableHeaderActions(for: detail).intersection(requested)

        return HStack(spacing: 10) {
            self.playButton(detail)
            self.shuffleButton(detail)

            if inline.contains(.radio), let mixPlaylistId = detail.mixPlaylistId {
                self.headerActionButton(
                    title: String(localized: "Start Radio"),
                    systemImage: StartRadioContextMenu.systemImage,
                    identifier: AccessibilityID.PlaylistDetail.radioButton,
                    showsTitle: showsTitles
                ) {
                    StartRadioContextMenu.startMix(
                        mixPlaylistId: mixPlaylistId,
                        playerService: self.playerService
                    )
                }
            }

            if inline.contains(.playNext) {
                self.headerActionButton(
                    title: String(localized: "Play Next"),
                    systemImage: "text.insert",
                    identifier: AccessibilityID.PlaylistDetail.playNextButton,
                    showsTitle: showsTitles,
                    isDisabled: detail.tracks.isEmpty
                ) {
                    SongActionsHelper.addSongsToQueueNext(
                        detail.tracks,
                        playerService: self.playerService,
                        fallbackArtist: detail.author,
                        fallbackAlbum: self.makeFallbackAlbum(from: detail)
                    )
                }
            }

            if inline.contains(.addToQueue) {
                self.headerActionButton(
                    title: String(localized: "Add to Queue"),
                    systemImage: "text.append",
                    identifier: AccessibilityID.PlaylistDetail.addToQueueButton,
                    showsTitle: showsTitles,
                    isDisabled: detail.tracks.isEmpty
                ) {
                    SongActionsHelper.addSongsToQueueLast(
                        detail.tracks,
                        playerService: self.playerService,
                        fallbackArtist: detail.author,
                        fallbackAlbum: self.makeFallbackAlbum(from: detail)
                    )
                }
            }

            if inline.contains(.library) {
                let isInLibrary = self.isInLibrary || self.isAddedToLibrary
                self.headerActionButton(
                    title: isInLibrary ? String(localized: "Remove from Library") : String(localized: "Add to Library"),
                    systemImage: isInLibrary ? "minus.circle" : "plus.circle",
                    identifier: AccessibilityID.PlaylistDetail.libraryButton,
                    showsTitle: showsTitles
                ) {
                    self.toggleLibrary()
                }
            }

            if inline.contains(.refine) {
                self.headerActionButton(
                    title: String(localized: "Refine Playlist"),
                    systemImage: "sparkles",
                    identifier: AccessibilityID.PlaylistDetail.refineButton,
                    showsTitle: showsTitles
                ) {
                    self.showRefineSheet = true
                }
                .requiresIntelligence()
            }

            // Only when it holds something: on an album the row can fit every action the page has, and an
            // empty menu is a control that opens nothing.
            if self.hasOverflowItems(for: detail, inline: inline) {
                self.moreActionsMenu(detail, inline: inline)
            }
        }
    }

    private func playButton(_ detail: PlaylistDetail) -> some View {
        Button {
            let fallbackAlbum = self.makeFallbackAlbum(from: detail)
            self.playAll(detail.tracks, fallbackArtist: detail.author, fallbackAlbum: fallbackAlbum)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .frame(height: Self.actionRowControlHeight)
        .disabled(detail.tracks.isEmpty)
        .accessibilityIdentifier(AccessibilityID.PlaylistDetail.playButton)
    }

    private func shuffleButton(_ detail: PlaylistDetail) -> some View {
        Button {
            let fallbackAlbum = self.makeFallbackAlbum(from: detail)
            self.playShuffled(detail.tracks, fallbackArtist: detail.author, fallbackAlbum: fallbackAlbum)
        } label: {
            Image(systemName: "shuffle")
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .frame(height: Self.actionRowControlHeight)
        .disabled(detail.tracks.isEmpty)
        .help("Shuffle")
        .accessibilityLabel("Shuffle")
        .accessibilityIdentifier(AccessibilityID.PlaylistDetail.shuffleButton)
    }

    /// One action of the row, styled exactly like the controls beside it.
    ///
    /// `showsTitle` is the row's own responsiveness: its widest shapes name their actions and its
    /// narrower shapes show the same actions as glyphs. Measured, naming a secondary action costs
    /// 134 pt of row where the same action as a glyph costs 53, so the named shapes are the ones with
    /// room to give back as the window narrows. A glyph keeps its action's name as the tooltip and as
    /// its accessibility label, so a narrower shape loses pixels, not meaning.
    private func headerActionButton(
        title: String,
        systemImage: String,
        identifier: String,
        showsTitle: Bool,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if showsTitle {
                Label(title, systemImage: systemImage)
            } else {
                Image(systemName: systemImage)
            }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .frame(height: Self.actionRowControlHeight)
        .disabled(isDisabled)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    /// Whether the row's overflow menu would hold anything.
    ///
    /// Two things decide it, and they are the two the menu itself would draw: the actions the row had no
    /// room for, and the page's own management.
    private func hasOverflowItems(for detail: PlaylistDetail, inline: HeaderAction) -> Bool {
        Self.showsOverflowMenu(
            available: self.availableHeaderActions(for: detail),
            inline: inline,
            showsManagement: detail.supportsPlaylistManagement
        )
    }

    /// Whether the overflow menu would hold anything: what the row had no room for, or the page's own
    /// management actions.
    ///
    /// A page that fits whole and has nothing to manage — an album, whose radio, two queue actions and
    /// library action all fit in the row — leaves the menu with nothing, and a `Menu` with no items is a
    /// control that opens nothing: that is how it read on an album page, where the three dots took a click
    /// and answered with an empty menu. The management half is `showsManagement` and not "is this an
    /// album": Liked Music is not an album, and it is the page this gate used to put Rename and Delete on.
    static func showsOverflowMenu(available: HeaderAction, inline: HeaderAction, showsManagement: Bool) -> Bool {
        !available.subtracting(inline).isEmpty || showsManagement
    }

    /// The row's overflow menu: the actions the row had no room for, then the playlist's own actions.
    ///
    /// The playlist's management — Rename and Delete — is always here: it is a menu's business rather
    /// than a row's, and the popover and alert it presents belong to the header (see `headerView`).
    ///
    /// It has to read as the button it sits beside, and a `Menu` cannot be given that look by a menu or
    /// button style. Left alone it keeps macOS's own pull-down chrome — a flat pill, measured 61.5 pt
    /// wide, with a chevron — over the row's glass. Under `.menuStyle(.button)` the chevron costs 27.5 pt
    /// (74.5 against 47 without) and the row's `.buttonStyle(.glass)` still does not reach the control.
    /// So the control is plain: no chrome of its own, no indicator, and a stated size and material — the
    /// same 46 by 26 pt Liquid Glass capsule the glyph buttons beside it come out at, measured in the
    /// running app. See ADR-0033.
    private func moreActionsMenu(_ detail: PlaylistDetail, inline: HeaderAction) -> some View {
        let fallbackAlbum = self.makeFallbackAlbum(from: detail)
        let isInLibrary = self.isInLibrary || self.isAddedToLibrary
        let inMenu = self.availableHeaderActions(for: detail).subtracting(inline)

        return Menu {
            if inMenu.contains(.radio), let mixPlaylistId = detail.mixPlaylistId {
                Button {
                    StartRadioContextMenu.startMix(
                        mixPlaylistId: mixPlaylistId,
                        playerService: self.playerService
                    )
                } label: {
                    Label("Start Radio", systemImage: StartRadioContextMenu.systemImage)
                }
                .accessibilityIdentifier(AccessibilityID.PlaylistDetail.radioButton)
            }

            if inMenu.contains(.playNext) {
                Button {
                    SongActionsHelper.addSongsToQueueNext(
                        detail.tracks,
                        playerService: self.playerService,
                        fallbackArtist: detail.author,
                        fallbackAlbum: fallbackAlbum
                    )
                } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
                .disabled(detail.tracks.isEmpty)
            }

            if inMenu.contains(.addToQueue) {
                Button {
                    SongActionsHelper.addSongsToQueueLast(
                        detail.tracks,
                        playerService: self.playerService,
                        fallbackArtist: detail.author,
                        fallbackAlbum: fallbackAlbum
                    )
                } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }
                .disabled(detail.tracks.isEmpty)
            }

            if inMenu.contains(.library) {
                Button {
                    self.toggleLibrary()
                } label: {
                    if isInLibrary {
                        Label(String(localized: "Remove from Library"), systemImage: "minus.circle")
                    } else {
                        Label(String(localized: "Add to Library"), systemImage: "plus.circle")
                    }
                }
            }

            if inMenu.contains(.refine) {
                Button {
                    self.showRefineSheet = true
                } label: {
                    Label("Refine Playlist", systemImage: "sparkles")
                }
                .requiresIntelligence()
            }

            // An album has no playlist to manage, and a page the reader cannot write to is not offered
            // writes the server answers with an error — see `PlaylistDetail.supportsPlaylistManagement`.
            // Liked Music is the page this section read wrong: it is the library's own list of liked
            // songs, not a playlist, and the account can neither rename nor delete it.
            if detail.supportsPlaylistManagement {
                Divider()

                Button {
                    self.playlistTitleDraft = detail.title
                    self.playlistActionError = nil
                    self.showRenamePlaylistPopover = true
                } label: {
                    Label("Rename Playlist", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    self.playlistActionError = nil
                    self.showDeletePlaylistAlert = true
                } label: {
                    Label("Delete Playlist", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: Self.overflowControlSize.width, height: Self.overflowControlSize.height)
                // One control, not three dots floating in a capsule. `.buttonStyle(.plain)` leaves a menu
                // hit-testing its label's *ink* rather than the label's 46 × 26 pt frame, so without this
                // the control opened only when a click landed on the ellipsis itself and the glass around
                // it was dead — the same fix the toolbar's back control carries.
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: .capsule)
        .frame(height: Self.actionRowControlHeight)
        .disabled(self.isRenamingPlaylist || self.isDeletingPlaylist)
        .help("More")
        .accessibilityLabel("More")
        .accessibilityIdentifier(AccessibilityID.PlaylistDetail.moreButton)
    }

    private func metadataText(for detail: PlaylistDetail) -> String {
        if let duration = detail.duration {
            return "\(detail.trackCountDisplay) • \(duration)"
        }

        return detail.trackCountDisplay
    }

    private var renamePlaylistPopover: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Rename Playlist")
                    .font(.headline)

                TextField("Playlist title", text: self.$playlistTitleDraft)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Spacer()

                    Button("Cancel") {
                        self.showRenamePlaylistPopover = false
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task {
                            await self.renamePlaylist()
                        }
                    } label: {
                        if self.isRenamingPlaylist {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(self.isRenamingPlaylist || self.playlistTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
            .frame(width: 300)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        }
    }

    /// Tracks list. Rows are individually equatable so player and paging updates no longer
    /// rebuild the visible window, and upcoming artwork is warmed ahead of the scroll.
    /// The track rows plus the paging spinner.
    @ViewBuilder
    private func trackRows(_ detail: PlaylistDetail, tracks: [Song]) -> some View {
        let isAlbum = detail.isAlbum
        // Read the player state once per pass: each row only needs to know whether *it* is the
        // current track, which keeps rows out of the observation dependency for playback.
        let currentVideoId = self.playerService.currentTrack?.videoId
        let isPlaying = self.playerService.isPlaying

        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            PlaylistTrackRow(
                song: track,
                index: index,
                isAlbum: isAlbum,
                isCurrentTrack: currentVideoId == track.videoId,
                isPlaying: isPlaying,
                showsSeparator: index < tracks.count - 1,
                isScrolling: self.isScrolling,
                favoritesManager: self.favoritesManager,
                likeStatusManager: self.likeStatusManager,
                playerService: self.playerService,
                client: self.viewModel.client,
                libraryViewModel: self.libraryViewModel,
                onPlay: { self.playTrack(in: tracks, at: index) },
                onRemoveFromPlaylist: { song in
                    Task {
                        await self.removeTrackFromCurrentPlaylist(song)
                    }
                }
            )
            .equatable()
            .listRowSeparator(.hidden)
            // No row insets: the row spans the full width of the list and insets its own content,
            // so its highlight can be full-bleed like the decoration `List` draws around the row a
            // right-click lands on (see ADR-0014). An inset row cannot be made to line up with it.
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }

        // Loading indicator for pagination. Paging itself is driven by scroll proximity,
        // so the fetch and this spinner sit below the visible window. Hidden while searching,
        // where the status row reports progress instead.
        if self.viewModel.loadingState == .loadingMore, self.viewModel.searchText.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .padding()
                Spacer()
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    /// Plays the row's queue from the list currently on screen, so a filtered result plays the
    /// filtered songs rather than the full playlist.
    private func playTrack(in tracks: [Song], at index: Int) {
        guard let detail = self.viewModel.playlistDetail,
              tracks.indices.contains(index)
        else { return }

        self.playTrackInQueue(
            tracks: tracks,
            startingAt: index,
            fallbackArtist: detail.author,
            fallbackAlbum: self.makeFallbackAlbum(from: detail)
        )
    }

    /// Warms the image cache for the rows the user is about to scroll into, at the same size
    /// the rows decode.
    private func prefetchUpcomingThumbnails(for tracks: [Song]) async {
        guard !Task.isCancelled else { return }

        let start = max(0, tracks.count - Self.thumbnailPrefetchWindow)
        let urls = tracks[start...].compactMap(\.thumbnailURL)
        guard !urls.isEmpty else { return }

        await ImageCache.shared.prefetch(
            urls: urls,
            targetSize: PlaylistTrackRow.thumbnailSize,
            maxConcurrent: 4
        )
    }

    // MARK: - Actions

    private func playTrackInQueue(tracks: [Song], startingAt index: Int, fallbackArtist: String? = nil, fallbackAlbum: Album? = nil) {
        let cleanedTracks = self.cleanTracks(
            tracks,
            fallbackArtist: fallbackArtist,
            fallbackAlbum: fallbackAlbum,
            forceLikedStatus: Self.isLikedMusicPlaylistId(self.playlist.id)
        )
        Task {
            await self.playerService.playQueue(cleanedTracks, startingAt: index)
        }
    }

    private func playAll(_ tracks: [Song], fallbackArtist: String? = nil, fallbackAlbum: Album? = nil) {
        guard !tracks.isEmpty else { return }
        let cleanedTracks = self.cleanTracks(
            tracks,
            fallbackArtist: fallbackArtist,
            fallbackAlbum: fallbackAlbum,
            forceLikedStatus: Self.isLikedMusicPlaylistId(self.playlist.id)
        )
        Task {
            await self.playerService.playQueue(cleanedTracks, startingAt: 0)
        }
    }

    private func playShuffled(_ tracks: [Song], fallbackArtist: String? = nil, fallbackAlbum: Album? = nil) {
        guard !tracks.isEmpty else { return }
        let cleanedTracks = self.cleanTracks(
            tracks,
            fallbackArtist: fallbackArtist,
            fallbackAlbum: fallbackAlbum,
            forceLikedStatus: Self.isLikedMusicPlaylistId(self.playlist.id)
        )
        let shuffledTracks = cleanedTracks.shuffled()
        Task {
            await self.playerService.playQueue(shuffledTracks, startingAt: 0)
        }
    }

    /// Cleans track artists and applies fallback artist/album when needed.
    private func cleanTracks(
        _ tracks: [Song],
        fallbackArtist: String?,
        fallbackAlbum: Album? = nil,
        forceLikedStatus: Bool = false
    ) -> [Song] {
        tracks.map { song in
            var cleanedArtists = song.artists.compactMap { artist -> Artist? in
                if artist.name == "Album" { return nil }
                var cleanName = artist.name
                if cleanName.hasPrefix("Album, ") {
                    cleanName = String(cleanName.dropFirst(7))
                }
                return Artist(id: artist.id, name: cleanName)
            }

            // Use fallback artist if artists are empty (and clean the fallback too)
            if cleanedArtists.isEmpty, let fallback = fallbackArtist, !fallback.isEmpty {
                var cleanFallback = fallback
                if cleanFallback == "Album" {
                    cleanFallback = "Unknown Artist"
                } else if cleanFallback.hasPrefix("Album, ") {
                    cleanFallback = String(cleanFallback.dropFirst(7))
                }
                // Also handle case where it's "Album, Artist" but we got it as a combined string
                if cleanFallback.contains("Album,") {
                    let parts = cleanFallback.split(separator: ",", maxSplits: 1)
                    if parts.count > 1 {
                        cleanFallback = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    }
                }
                cleanedArtists = [Artist(id: "unknown", name: cleanFallback)]
            }

            // Use fallback album if song doesn't have album info
            let finalAlbum = song.album ?? fallbackAlbum
            // Use fallback thumbnail if song doesn't have one
            let finalThumbnail = song.thumbnailURL ?? fallbackAlbum?.thumbnailURL
            let finalLikeStatus = forceLikedStatus ? .like : song.likeStatus

            return Song(
                id: song.id,
                title: song.title,
                artists: cleanedArtists,
                album: finalAlbum,
                duration: song.duration,
                thumbnailURL: finalThumbnail,
                videoId: song.videoId,
                hasVideo: song.hasVideo,
                musicVideoType: song.musicVideoType,
                likeStatus: finalLikeStatus,
                isInLibrary: song.isInLibrary,
                feedbackTokens: song.feedbackTokens
            )
        }
    }

    private func toggleLibrary() {
        let currentlyInLibrary = self.isInLibrary || self.isAddedToLibrary
        // The library's own item, not the page's: an album is saved under its audio playlist. The removal
        // below reaches a playlist the library already holds, which is the case the action is kept for on a
        // page whose own ID the library cannot hold.
        let item = self.libraryPlaylist
        HapticService.success()
        Task {
            let succeeded: Bool = if currentlyInLibrary {
                await SongActionsHelper.removePlaylistFromLibrary(
                    item,
                    client: self.viewModel.client,
                    libraryViewModel: self.libraryViewModel
                )
            } else {
                await SongActionsHelper.addPlaylistToLibrary(
                    item,
                    client: self.viewModel.client,
                    libraryViewModel: self.libraryViewModel
                )
            }

            // The control follows the server, not the click. Flipping it whatever happened left the page
            // claiming an item was saved when the write had failed, and the next click then tried to remove
            // something that was never added.
            if succeeded {
                self.isAddedToLibrary = !currentlyInLibrary
                self.playlistActionError = nil
            } else {
                self.isAddedToLibrary = false
                self.playlistActionError = currentlyInLibrary
                    ? String(localized: "Couldn't remove this from your library. Try again.")
                    : String(localized: "Couldn't add this to your library. Try again.")
            }
        }
    }

    private func renamePlaylist() async {
        let trimmedTitle = self.playlistTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        self.isRenamingPlaylist = true
        defer { self.isRenamingPlaylist = false }

        do {
            try await self.viewModel.client.renamePlaylist(playlistId: self.playlist.id, newTitle: trimmedTitle)
            self.libraryViewModel?.updatePlaylistTitle(playlistId: self.playlist.id, newTitle: trimmedTitle)
            self.libraryViewModel?.markNeedsReloadOnActivation()
            self.playlistActionError = nil
            self.showRenamePlaylistPopover = false
            await self.viewModel.refresh()
            await self.libraryViewModel?.refreshFromNetwork()
        } catch {
            self.playlistActionError = error.localizedDescription
            DiagnosticsLogger.api.error("Failed to rename playlist: \(error.localizedDescription)")
        }
    }

    private func removeTrackFromCurrentPlaylist(_ track: Song) async {
        do {
            if Self.isLikedMusicPlaylistId(self.playlist.id) {
                try await self.viewModel.client.rateSong(videoId: track.videoId, rating: .indifferent)
            } else {
                try await self.viewModel.client.removeSongFromPlaylist(
                    videoId: track.videoId,
                    playlistId: self.playlist.id,
                    setVideoId: nil
                )
            }

            self.playlistActionError = nil
            self.libraryViewModel?.markNeedsReloadOnActivation()
            await self.viewModel.refresh()
            await self.libraryViewModel?.refreshFromNetwork()
        } catch {
            self.playlistActionError = error.localizedDescription
            DiagnosticsLogger.api.error("Failed to remove track from playlist: \(error.localizedDescription)")
        }
    }

    private static func isLikedMusicPlaylistId(_ playlistId: String) -> Bool {
        if playlistId == "LM" || playlistId == "VLLM" {
            return true
        }

        if playlistId.hasPrefix("VL") {
            return String(playlistId.dropFirst(2)) == "LM"
        }

        return false
    }

    private func deletePlaylist() async {
        self.isDeletingPlaylist = true
        defer { self.isDeletingPlaylist = false }

        do {
            try await self.viewModel.client.deletePlaylist(playlistId: self.playlist.id)
            self.libraryViewModel?.removeFromLibrary(playlistId: self.playlist.id)
            self.libraryViewModel?.markNeedsReloadOnActivation()
            self.playlistActionError = nil
            await self.libraryViewModel?.refreshFromNetwork()
            self.dismiss()
        } catch {
            self.playlistActionError = error.localizedDescription
            DiagnosticsLogger.api.error("Failed to delete playlist: \(error.localizedDescription)")
        }
    }

    private func refinePlaylist(tracks: [Song], prompt: String) async {
        self.isRefining = true
        self.refineError = nil
        self.playlistChanges = nil
        self.partialChanges = nil

        self.logger.info("Refining playlist with prompt: \(prompt)")

        let instructions = """
        You are a music playlist curator. Analyze songs and suggest changes based on the request.

        IMPORTANT RULES:
        - A "duplicate" means the EXACT same video ID appears twice. Different versions/covers
          of a song by different artists are NOT duplicates.
        - "Last Christmas" by Wham! and "Last Christmas" by Jimmy Eat World are DIFFERENT songs.
        - Only suggest removing tracks that truly don't fit the user's criteria.
        - When in doubt, keep the song.
        """

        // Use analysis session for creative playlist curation
        guard let session = FoundationModelsService.shared.createAnalysisSession(instructions: instructions) else {
            self.refineError = "Apple Intelligence is not available"
            self.isRefining = false
            return
        }

        // Build track list - limit to 25 to reduce content filter issues
        let trackLimit = min(tracks.count, 25)
        let trackList = tracks.prefix(trackLimit).enumerated().map { index, track in
            // Sanitize track info to reduce content filter triggers
            let safeTitle = track.title.prefix(50)
            let safeArtist = track.artistsDisplay.prefix(30)
            return "\(index + 1). \(safeTitle) - \(safeArtist) [id:\(track.videoId)]"
        }.joined(separator: "\n")

        let userPrompt = """
        Playlist (\(tracks.count) songs, showing \(trackLimit)):

        \(trackList)

        Request: \(prompt)
        """

        do {
            // Use streaming for progressive UI updates
            let stream = session.streamResponse(to: userPrompt, generating: PlaylistChanges.self)

            for try await snapshot in stream {
                // Update partial content for streaming UI
                self.partialChanges = snapshot.content
            }

            // Stream complete - convert final partial to complete changes
            if let final = self.partialChanges,
               let removals = final.removals,
               let reasoning = final.reasoning
            {
                self.playlistChanges = PlaylistChanges(
                    removals: removals,
                    reorderedIds: final.reorderedIds,
                    reasoning: reasoning
                )
                self.logger.info("Got playlist changes: \(removals.count) removals")
            }
        } catch {
            // Use centralized error handler for consistent messaging
            if let message = AIErrorHandler.handleAndMessage(error, context: "playlist refinement") {
                self.refineError = message
            }
        }

        self.partialChanges = nil
        self.isRefining = false
    }
}

// MARK: - RefinePlaylistSheet

@available(macOS 26.0, *)
private struct RefinePlaylistSheet: View {
    let tracks: [Song]
    @Binding var isProcessing: Bool
    @Binding var changes: PlaylistChanges?
    @Binding var partialChanges: PlaylistChanges.PartiallyGenerated?
    @Binding var errorMessage: String?
    let onRefine: (String) async -> Void
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var promptText = ""
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Refine Playlist")
                    .font(.headline)
                Spacer()
                Button {
                    self.dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding()

            Divider()

            // Content
            if self.isProcessing {
                if let partial = partialChanges {
                    self.streamingChangesView(partial)
                } else {
                    self.loadingView
                }
            } else if let changes {
                self.changesView(changes)
            } else {
                self.promptView
            }
        }
        .frame(width: 500, height: 400)
        .onAppear {
            self.isPromptFocused = true
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.regular)
                .frame(width: 20, height: 20)
            Text("Analyzing playlist...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shows partial changes as they stream in from the AI.
    private func streamingChangesView(_ partial: PlaylistChanges.PartiallyGenerated) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Reasoning (shows as it streams)
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 10, height: 10)
                if let reasoning = partial.reasoning {
                    Text(reasoning)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Analyzing...")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal)

            Divider()

            // Changes list (shows as items stream in)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let removals = partial.removals, !removals.isEmpty {
                        Text("Suggested Removals")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)

                        ForEach(removals, id: \.self) { videoId in
                            if let track = tracks.first(where: { $0.videoId == videoId }) {
                                HStack {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                    Text(track.title)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(track.artistsDisplay)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }

            Spacer()

            // Disabled actions during streaming
            HStack {
                Spacer()
                Text("Processing...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
        }
    }

    private var promptView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What would you like to change?")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("e.g., Remove slow songs, reorder by energy...", text: self.$promptText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3 ... 5)
                .focused(self.$isPromptFocused)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                self.suggestionChip("Remove duplicates")
                self.suggestionChip("Make it more upbeat")
                self.suggestionChip("Better flow")
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") {
                    self.dismiss()
                }
                .keyboardShortcut(.escape)

                Button("Refine") {
                    Task {
                        await self.onRefine(self.promptText)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(self.promptText.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return)
            }
        }
        .padding()
    }

    private func changesView(_ changes: PlaylistChanges) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Reasoning
            Text(changes.reasoning)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Divider()

            // Changes list
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !changes.removals.isEmpty {
                        Text("Suggested Removals")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)

                        ForEach(changes.removals, id: \.self) { videoId in
                            if let track = tracks.first(where: { $0.videoId == videoId }) {
                                HStack {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                    Text(track.title)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(track.artistsDisplay)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    if changes.removals.isEmpty, changes.reorderedIds == nil {
                        Text("No changes suggested. The playlist looks good!")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
            }

            Divider()

            // Actions
            HStack {
                Button("Try Again") {
                    self.changes = nil
                    self.errorMessage = nil
                }

                Spacer()

                Button("Cancel") {
                    self.dismiss()
                }
                .keyboardShortcut(.escape)

                Button("Apply Changes") {
                    self.onApply()
                }
                .buttonStyle(.borderedProminent)
                .disabled(changes.removals.isEmpty && changes.reorderedIds == nil)
            }
            .padding()
        }
    }

    private func suggestionChip(_ text: String) -> some View {
        Button {
            self.promptText = text
        } label: {
            Text(text)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - PlaylistToolbarControls

/// The playlist's own controls — search, sort, refresh — as the window toolbar's page item.
///
/// A view type rather than the page's own computed properties, because the toolbar hosts it in a
/// **different view tree**: the only thing that makes it update there is reading the page's model during
/// a render of *that* tree, so the field, the menu and the spinner all read `viewModel` here, in `body`.
/// (A value read when the page published its controls would be a snapshot: the spinner would never
/// start, and a changed sort order would not show up in the menu.) The same model is what the list below
/// the toolbar renders, which is what keeps the two in step — a query typed in the titlebar filters the
/// rows under it in the same pass.
@available(macOS 26.0, *)
private struct PlaylistToolbarControls: View {
    let viewModel: PlaylistDetailViewModel
    /// The library snapshot a manual refresh also renews, so the page's "in library" state stays
    /// current. Passed as a value because the toolbar's tree has none of the page's environment.
    let library: LibraryViewModel?

    var body: some View {
        HStack(spacing: 10) {
            self.searchField

            // Always in the layout, even before the detail says whether sorting exists. Adding the menu
            // only once loaded resized the toolbar's hosted item mid-load, which AppKit answered by
            // re-laying the whole titlebar — the controls beside it visibly jumped. The placeholder is
            // the same label shape with no content, so the width is already there when the menu arrives.
            if let detail = self.viewModel.playlistDetail, detail.isSortable {
                self.sortMenu(detail)
            } else {
                self.sortMenuPlaceholder
            }

            PageRefreshButton(
                help: "Refresh",
                isRefreshing: { self.viewModel.isRefreshing },
                action: {
                    Task { await self.viewModel.performRefresh(library: self.library) }
                }
            )
        }
        // Search covers the whole playlist, so pull the remaining pages the first time a query is typed
        // instead of only filtering what has already scrolled into view.
        .onChange(of: self.viewModel.searchText) { _, newValue in
            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { await self.viewModel.loadAllTracksForSearch() }
        }
    }

    /// Compact toolbar search field. Fixed width keeps it from stretching across the toolbar; the
    /// toolbar supplies the container background, so no extra glass is layered on top.
    private var searchField: some View {
        @Bindable var viewModel = self.viewModel

        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField(String(localized: "Search in playlist"), text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .frame(width: 140)

            if !self.viewModel.searchText.isEmpty {
                Button {
                    self.viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear search"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// The sort menu's slot while there is no menu to show: the same label with no behaviour, so the
    /// toolbar item keeps its width from the first frame instead of growing into it after the load.
    private var sortMenuPlaceholder: some View {
        Label(String(localized: "Sort"), systemImage: "arrow.up.arrow.down")
            .opacity(0)
            .accessibilityHidden(true)
    }

    /// Toolbar menu that mirrors YouTube Music's playlist sort options. The active order is shown by the
    /// check mark in the dropdown; choosing one writes the order to the account and reloads the tracks
    /// in the new order.
    private func sortMenu(_ detail: PlaylistDetail) -> some View {
        Menu {
            // Toggles render as menu items with a check mark, which is what actually shows the active
            // order in a macOS menu (a `Label` image does not).
            ForEach(detail.sortOptions, id: \.self) { order in
                Toggle(order.displayName, isOn: Binding(
                    get: { detail.effectiveSortOrder == order },
                    set: { isSelected in
                        guard isSelected else { return }
                        Task { await self.viewModel.changeSortOrder(to: order) }
                    }
                ))
            }
        } label: {
            Label(String(localized: "Sort"), systemImage: "arrow.up.arrow.down")
        }
        .help(Text("Sort by \(detail.effectiveSortOrder.displayName). This order is saved to your YouTube Music account."))
        .disabled(self.viewModel.isChangingSortOrder)
    }
}

#Preview {
    let playlist = Playlist(
        id: "test",
        title: "Test Playlist",
        description: nil,
        thumbnailURL: nil,
        trackCount: 10,
        author: "Test Author"
    )
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    PlaylistDetailView(
        playlist: playlist,
        viewModel: PlaylistDetailViewModel(
            playlist: playlist,
            client: client
        ),
        // The preview has no navigation stack to push onto.
        onNavigateToArtist: { _ in }
    )
    .environment(PlayerService())
    .environment(AccountService(ytMusicClient: client, authService: authService))
}
