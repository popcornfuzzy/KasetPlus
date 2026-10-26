import AppKit
import SwiftUI
import Testing

@testable import Kaset

/// The Now Playing column's title and artist line, clicked in the real column, inside a real page's
/// navigation stack, for the tracks the player actually produces.
///
/// Every other test around these credits checks one piece — the rules, the hitbox, the push. This one
/// is the shape the app has: the column is a sibling of the page, it hands its route to the window
/// (`PageNavigationModel`, published by the stack on screen), and the destination page appears. Both
/// playback paths are covered because they reach the column with different data:
///
/// - a song started from a page arrives with its queue row, so its album and its artists' channel IDs
///   are on hand;
/// - a song YouTube started itself (autoplay after the queue, a radio station) arrives with one
///   byline artist that has no ID and no album at all, and the column resolves both through the API.
///
/// Not covered here, and not coverable offscreen: what the column looks like while all this happens.
@MainActor
@Suite(.serialized)
struct NowPlayingSidebarCreditNavigationTests {
    /// The page the credits were pushed onto, read from the destination views themselves.
    @Observable
    final class Visited {
        var albums: [String] = []
        var artists: [String] = []
        /// Routes the window had to open itself, because no page on screen published a stack — Home,
        /// Search and the artist pages have none. `MainWindow` shows those in the content pane.
        var openedByTheWindow: [DetailNavigationRoute] = []
    }

    @Observable
    final class PathBox {
        var path = NavigationPath()
    }

    private static let pageWidth: CGFloat = 500
    private static let columnWidth: CGFloat = 380
    private static let windowHeight: CGFloat = 700
    private static let windowWidth = Self.pageWidth + Self.columnWidth

    // MARK: - Tracks

    /// What a song played from a page looks like: its queue row carries the album and three artists
    /// with channel IDs, which is what the WebView's byline observation can strip afterwards.
    private func pageSong() -> Song {
        Song(
            id: "video-1",
            title: "A Song",
            artists: [
                Artist(id: "UCone", name: "One"),
                Artist(id: "UCtwo", name: "Two"),
                Artist(id: "UCthree", name: "Three"),
            ],
            album: Album(
                id: "MPREb_album",
                title: "An Album",
                artists: nil,
                thumbnailURL: nil,
                year: nil,
                trackCount: 3
            ),
            duration: 200,
            thumbnailURL: nil,
            videoId: "video-1"
        )
    }

    /// What `PlayerService` holds for a track YouTube started itself: the byline's words as one artist
    /// without an ID, and no album.
    private func autoplayTrack() -> Song {
        Song(
            id: "video-2",
            title: "Autoplay Song",
            artists: [Artist(id: "unknown", name: "One, Two")],
            album: nil,
            duration: 200,
            thumbnailURL: nil,
            videoId: "video-2"
        )
    }

    // MARK: - Harness

    private func makePlayer() -> PlayerService {
        let settings = SettingsManager.shared
        // The column searches lyrics and canvas for whatever is playing; both are network work this
        // test has no business starting. (The flags are restored by the test's `defer`.)
        settings.syncedLyricsEnabled = false
        settings.animatedCanvasEnabled = false
        let player = PlayerService()
        player.setNowPlayingSidebarPage(.overview)
        return player
    }

    /// Hosts the page and the column side by side, exactly as the window does: the column is not inside
    /// the page's stack, and reaches it only through the route the window hands on.
    private func host(
        player: PlayerService,
        client: MockYTMusicClient = MockYTMusicClient(),
        pageHasStack: Bool = true
    ) -> (window: NSWindow, visited: Visited) {
        let model = PageNavigationModel()
        let box = PathBox()
        let visited = Visited()
        let path = Binding(get: { box.path }, set: { box.path = $0 })

        let home = Text("HOME")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationDestination(for: Playlist.self) { playlist in
                Text("ALBUM \(playlist.title)")
                    .onAppear { visited.albums.append(playlist.id) }
            }
            .navigationDestination(for: Artist.self) { artist in
                Text("ARTIST \(artist.name)")
                    .onAppear { visited.artists.append(artist.id) }
            }

        // A page with a stack publishes where to push; a page without one — Home, Search, an artist page —
        // publishes nothing, which is what the window answers by showing the page in the content pane.
        let page = Group {
            if pageHasStack {
                PageNavigationStack(id: "credit-test-home", path: path) { home }
            } else {
                home
            }
        }
        .environment(model)

        let column = NowPlayingSidebarView(
            columnWidth: Self.columnWidth,
            columnHeight: Self.windowHeight,
            topInset: 0,
            onOpen: { route in
                guard !model.open(route) else { return }
                visited.openedByTheWindow.append(route)
            }
        )
        .environment(player)
        .environment(SyncedLyricsService())
        .environment(CanvasService())
        .environment(PodcastTranscriptService(client: client))
        .environment(FavoritesManager.shared)

        let root = HStack(spacing: 0) {
            page.frame(width: Self.pageWidth)
            column.frame(width: Self.columnWidth)
        }
        .frame(width: Self.windowWidth, height: Self.windowHeight, alignment: .topLeading)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight)
        hosting.layoutSubtreeIfNeeded()

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        // A press needs a window; the reader does not need to see it. Fully transparent, closed by the
        // test that made it — these used to put real windows on the desktop, one per run.
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.orderBack(nil)
        self.pump(1.0)
        return (window, visited)
    }

    private func pump(_ seconds: Double = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
    }

    private func click(in window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else {
                Issue.record("the harness could not build a \(type) event")
                return
            }
            window.sendEvent(event)
        }
        self.pump(0.2)
    }

    /// The credit rows in the column at this harness's size.
    ///
    /// The artwork is the column's width square (380 pt) at the top of a 700 pt column, so the title
    /// line sits just below 380 from the top and the artist line under it. Stated here as one place so
    /// a layout change fails these tests loudly instead of silently pressing the lyric card.
    private static let titleY: CGFloat = 700 - 392
    private static let artistY: CGFloat = 700 - 412
    /// The column's trailing edge, which is inside the title's full-row target.
    private static var titleX: CGFloat { Self.windowWidth - 20 }
    /// Just inside the artist line's left edge, over the first credited name.
    private static var artistX: CGFloat { Self.pageWidth + 25 }

    // MARK: - Tests

    @Test("A song played from a page opens its album and the artist that was clicked")
    func pageSongCreditsOpenPages() {
        let settings = SettingsManager.shared
        let lyrics = settings.syncedLyricsEnabled
        let canvas = settings.animatedCanvasEnabled
        defer {
            settings.syncedLyricsEnabled = lyrics
            settings.animatedCanvasEnabled = canvas
        }

        let player = self.makePlayer()
        let song = self.pageSong()
        player.queue = [song]
        player.currentIndex = 0
        player.currentTrack = song

        let (window, visited) = self.host(player: player)

        // The title's button is the row's whole width, so the column's trailing edge is on it.
        self.click(in: window, at: NSPoint(x: Self.titleX, y: Self.titleY))
        #expect(visited.albums == ["MPREb_album"], "the title row must open the album")

        // The artist line is left-aligned; this point is over the first name.
        self.click(in: window, at: NSPoint(x: Self.artistX, y: Self.artistY))
        #expect(visited.artists == ["UCone"], "the first name must open its own artist")
    }

    @Test("On a page with no stack, a credit click is handed to the window instead of doing nothing")
    func creditsOnAPageWithoutAStackAreHandedToTheWindow() {
        let settings = SettingsManager.shared
        let lyrics = settings.syncedLyricsEnabled
        let canvas = settings.animatedCanvasEnabled
        defer {
            settings.syncedLyricsEnabled = lyrics
            settings.animatedCanvasEnabled = canvas
        }

        let player = self.makePlayer()
        let song = self.pageSong()
        player.queue = [song]
        player.currentIndex = 0
        player.currentTrack = song

        let (window, visited) = self.host(player: player, pageHasStack: false)

        self.click(in: window, at: NSPoint(x: Self.titleX, y: Self.titleY))
        self.click(in: window, at: NSPoint(x: Self.artistX, y: Self.artistY))

        #expect(visited.openedByTheWindow.count == 2, "both clicks must reach the window")
        #expect(visited.albums.isEmpty, "nothing was pushed: this page has no stack")

        if case let .album(playlist)? = visited.openedByTheWindow.first {
            #expect(playlist.id == "MPREb_album")
        } else {
            Issue.record("the title must hand the window its album")
        }

        if case let .artist(artist)? = visited.openedByTheWindow.last {
            #expect(artist.id == "UCone", "the first name must hand the window that artist")
        } else {
            Issue.record("the artist line must hand the window that artist")
        }
    }

    @Test("The credits open pages when the column is an AppKit split view's inspector pane")
    func creditsInASplitViewInspectorPaneOpen() {
        let settings = SettingsManager.shared
        let lyrics = settings.syncedLyricsEnabled
        let canvas = settings.animatedCanvasEnabled
        defer {
            settings.syncedLyricsEnabled = lyrics
            settings.animatedCanvasEnabled = canvas
        }

        let model = PageNavigationModel()
        let box = PathBox()
        let visited = Visited()
        let path = Binding(get: { box.path }, set: { box.path = $0 })

        let page = PageNavigationStack(id: "credit-test-split", path: path) {
            Text("HOME")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationDestination(for: Playlist.self) { playlist in
                    Text("ALBUM \(playlist.title)")
                        .onAppear { visited.albums.append(playlist.id) }
                }
                .navigationDestination(for: Artist.self) { artist in
                    Text("ARTIST \(artist.name)")
                        .onAppear { visited.artists.append(artist.id) }
                }
        }
        .environment(model)

        let player = self.makePlayer()
        let song = self.pageSong()
        player.queue = [song]
        player.currentIndex = 0
        player.currentTrack = song

        let client = MockYTMusicClient()
        let column = NowPlayingSidebarView(
            columnWidth: Self.columnWidth,
            columnHeight: Self.windowHeight,
            topInset: 0,
            onOpen: { model.open($0) }
        )
        .environment(player)
        .environment(SyncedLyricsService())
        .environment(CanvasService())
        .environment(PodcastTranscriptService(client: client))
        .environment(FavoritesManager.shared)

        // The window's own shape: two AppKit panes, each a hosting controller, the column a sibling of
        // the page rather than a sibling view inside one hierarchy.
        let split = NSSplitViewController()
        let contentPane = NSSplitViewItem(viewController: NSHostingController(
            rootView: page.frame(width: Self.pageWidth, height: Self.windowHeight)
        ))
        contentPane.minimumThickness = Self.pageWidth
        let inspectorPane = NSSplitViewItem(viewController: NSHostingController(
            rootView: column.frame(width: Self.columnWidth, height: Self.windowHeight)
        ))
        inspectorPane.minimumThickness = Self.columnWidth
        split.addSplitViewItem(contentPane)
        split.addSplitViewItem(inspectorPane)

        let hosting = split.view
        hosting.frame = NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight)
        hosting.layoutSubtreeIfNeeded()

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.orderBack(nil)
        self.pump(1.0)

        self.click(in: window, at: NSPoint(x: Self.titleX, y: Self.titleY))
        self.click(in: window, at: NSPoint(x: Self.artistX, y: Self.artistY))

        #expect(visited.albums == ["MPREb_album"], "the title row must open the album through the panes")
        #expect(visited.artists == ["UCone"], "the first name must open its own artist through the panes")
    }

    @Test("An autoplay track's credits are YouTube Music's own record of the track, and they open")
    func autoplayCreditsComeFromTheAPIRecordAndOpen() async {
        let settings = SettingsManager.shared
        let lyrics = settings.syncedLyricsEnabled
        let canvas = settings.animatedCanvasEnabled
        defer {
            settings.syncedLyricsEnabled = lyrics
            settings.animatedCanvasEnabled = canvas
        }

        let player = self.makePlayer()
        player.queue = []
        player.currentTrack = self.autoplayTrack()

        // What YouTube Music knows about the video: the `next` endpoint's record of it. Nothing here is
        // derived from the byline the page renders.
        let client = MockYTMusicClient()
        client.songResponses["video-2"] = Song(
            id: "video-2",
            title: "Autoplay Song",
            artists: [Artist(id: "UCone", name: "One"), Artist(id: "UCtwo", name: "Two")],
            album: Album(
                id: "MPREb_auto",
                title: "Autoplay Album",
                artists: nil,
                thumbnailURL: nil,
                year: "2017",
                trackCount: 4
            ),
            duration: 200,
            thumbnailURL: nil,
            videoId: "video-2",
            likeStatus: .like,
            isInLibrary: true
        )
        player.setYTMusicClient(client)

        // An autoplay track reaches the app through the page's observation, never through `play(song:)`.
        player.updateTrackMetadata(
            title: "Autoplay Song",
            artist: "One, Two",
            thumbnailUrl: "",
            videoId: "video-2",
            playerBarVideoId: "video-2"
        )

        // The record is asked for once, in the background, when the track starts. A hosted window in a
        // test does not repaint after it is ordered (nothing is on screen), so the record is allowed to
        // land before the column is presented — the same state the app is in a moment after a start.
        for _ in 0 ..< 40 where player.currentTrack?.album?.id != "MPREb_auto" {
            try? await Task.sleep(for: .milliseconds(50))
        }

        let (window, visited) = self.host(player: player, client: client)
        self.pump(0.3)

        #expect(player.currentTrack?.album?.id == "MPREb_auto", "the album comes from the record")
        #expect(player.currentTrack?.artists.map(\.id) == ["UCone", "UCtwo"])
        #expect(player.currentTrackLikeStatus == .like, "the like status comes from the record")
        #expect(player.currentTrackInLibrary == true, "the library state comes from the record")

        self.click(in: window, at: NSPoint(x: Self.titleX, y: Self.titleY))
        #expect(visited.albums == ["MPREb_auto"], "the record's album must be clickable")

        self.click(in: window, at: NSPoint(x: Self.artistX, y: Self.artistY))
        #expect(visited.artists == ["UCone"], "the record's artists must be clickable")
    }
}
