import AppKit
import SwiftUI
import Testing
@testable import Kaset

/// Tests for the queue rows' right-click menu.
///
/// The menu is what makes a queue row actionable without playing it, and it is the one the Now Playing
/// sidebar's queue page inherits from this panel. It used to be built in a method AppKit never calls —
/// there is no `menuForRow` on `NSTableViewDelegate` — so a right click on a queue row opened nothing at
/// all. These tests state both halves of the fix: the menu the coordinator builds, and the table routing
/// a right click to it.
@Suite(.serialized)
@MainActor
struct QueueSidePanelMenuTests {
    private func makeCoordinator(
        queue: [Song] = TestFixtures.makeSongs(count: 3),
        currentIndex: Int = 0
    ) -> QueueListControllerRepresentable.Coordinator {
        QueueListControllerRepresentable.Coordinator(
            queue: queue,
            currentIndex: currentIndex,
            isPlaying: false,
            onSelect: { _ in },
            onReorder: { _, _ in nil },
            onRemove: { _ in },
            onStartRadio: { _ in }
        )
    }

    private func menuTitles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    @Test("A queue row's menu offers the song's own actions")
    func rowMenuOffersSongActions() {
        let coordinator = self.makeCoordinator()

        let menu = coordinator.menu(forRow: 1)

        let titles = menu.map(self.menuTitles) ?? []
        #expect(titles.contains("Start Radio"))
        #expect(titles.contains("Share"))
        #expect(titles.contains("Remove from Queue"))
    }

    @Test("The playing row has no Remove from Queue")
    func playingRowCannotBeRemoved() {
        let coordinator = self.makeCoordinator(currentIndex: 1)

        let menu = coordinator.menu(forRow: 1)

        let titles = menu.map(self.menuTitles) ?? []
        #expect(titles.contains("Start Radio"))
        #expect(titles.contains("Remove from Queue") == false)
    }

    @Test("A click below the last row has no menu")
    func clickOutsideTheRowsHasNoMenu() {
        let coordinator = self.makeCoordinator()

        #expect(coordinator.menu(forRow: 3) == nil)
        #expect(coordinator.menu(forRow: -1) == nil)
    }

    @Test("Right-clicking a queue row opens its menu")
    func rightClickOpensTheRowMenu() {
        let queue = TestFixtures.makeSongs(count: 3)
        let coordinator = self.makeCoordinator(queue: queue)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let table = DraggableTableView(frame: NSRect(x: 0, y: 0, width: 350, height: 240))
        table.rowHeight = 56
        table.delegate = coordinator
        table.dataSource = coordinator
        table.coordinator = coordinator
        // Hosted the way the panel hosts it: inside a scroll view, which is what lays the rows out.
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 350, height: 240))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = table
        window.contentView?.addSubview(scrollView)
        table.reloadData()
        table.layoutSubtreeIfNeeded()

        // The middle of the second row, in the window's coordinates — where a right click on that row
        // lands.
        #expect(table.numberOfRows == 3)
        #expect(table.rect(ofRow: 1).isEmpty == false)
        let rowPoint = NSPoint(x: 40, y: table.rect(ofRow: 1).midY)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: table.convert(rowPoint, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )

        #expect(event != nil)
        #expect(event.map { table.row(at: table.convert($0.locationInWindow, from: nil)) } == 1)

        let menu = event.flatMap { table.menu(for: $0) }

        let titles = menu.map(self.menuTitles) ?? []
        #expect(titles.contains("Start Radio"))
        #expect(titles.contains("Remove from Queue"))
    }

    // MARK: - The full song menu

    /// A coordinator with the services the app hands the panel, which is what brings the song's own
    /// actions into a row's menu.
    private func makeFullCoordinator(
        // IDs of their own: Like and Dislike are titled from `SongLikeStatusManager.shared`, which the
        // suites before this one have already written to for the shared fixture IDs.
        queue: [Song] = [
            TestFixtures.makeSong(id: "queue-menu-1", title: "Song 1"),
            TestFixtures.makeSong(id: "queue-menu-2", title: "Song 2"),
        ],
        currentIndex: Int = 0,
        onOpen: @escaping (DetailNavigationRoute) -> Void = { _ in },
        onAddToPlaylist: @escaping (Song, CGRect) -> Void = { _, _ in }
    ) -> QueueListControllerRepresentable.Coordinator {
        let client = MockYTMusicClient()
        return QueueListControllerRepresentable.Coordinator(
            queue: queue,
            currentIndex: currentIndex,
            isPlaying: false,
            onSelect: { _ in },
            onReorder: { _, _ in nil },
            onRemove: { _ in },
            onStartRadio: { _ in },
            playerService: PlayerService(),
            client: client,
            likeStatusManager: SongLikeStatusManager.shared,
            libraryViewModel: LibraryViewModel(client: client),
            onOpen: onOpen,
            onAddToPlaylist: onAddToPlaylist
        )
    }

    @Test("A queue row's menu offers the whole song menu, not only the queue's own actions")
    func rowMenuOffersTheFullSongMenu() {
        let coordinator = self.makeFullCoordinator()

        let titles = coordinator.menu(forRow: 1).map(self.menuTitles) ?? []

        // Every action the app's other song menus offer (`PlaylistTrackMenuContent`), plus the
        // queue's own removal.
        for title in [
            "Play",
            "Like",
            "Dislike",
            "Start Radio",
            "Add to Library",
            "Share",
            "Play Next",
            "Add to Queue",
            "Add to Playlist",
            "Remove from Queue",
            "Go to Artist",
        ] {
            #expect(titles.contains(title), "a queue row's menu is missing \(title)")
        }
    }

    @Test("Go to Album in a row's menu hands the window the album")
    func goToAlbumOpensTheAlbum() throws {
        let song = Song(
            id: "video-1",
            title: "A Song",
            artists: [Artist(id: "UCone", name: "One")],
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
        var opened: [DetailNavigationRoute] = []
        let coordinator = self.makeFullCoordinator(queue: [song, song], onOpen: { opened.append($0) })

        let menu = try #require(coordinator.menu(forRow: 0))
        let albumItem = menu.indexOfItem(withTitle: "Go to Album")
        #expect(albumItem >= 0, "the row names an album, so its menu must open it")
        menu.performActionForItem(at: albumItem)

        #expect(opened.count == 1)
        if case let .album(playlist)? = opened.first {
            #expect(playlist.id == "MPREb_album")
        } else {
            Issue.record("Go to Album must hand the window the album, not \(String(describing: opened.first))")
        }
    }

    @Test("Add to Playlist opens the playlist popover for the row that was clicked")
    func addToPlaylistOpensThePopoverForTheClickedRow() throws {
        // Row 0 is the playing song; row 1 is not, so the assertion below cannot pass by accident.
        var requested: [(song: Song, anchor: CGRect)] = []
        let coordinator = self.makeFullCoordinator(onAddToPlaylist: { requested.append(($0, $1)) })

        let menu = try #require(coordinator.menu(forRow: 1))
        let playlistItem = menu.indexOfItem(withTitle: "Add to Playlist")
        #expect(playlistItem >= 0, "the row's menu must offer Add to Playlist")
        // A submenu is assembled with the menu, before the library has answered — which is why it held
        // nothing but Create Playlist. The playlists belong to the popover, which loads them.
        #expect(menu.item(at: playlistItem)?.submenu == nil, "the playlists are the popover's, not a submenu's")

        menu.performActionForItem(at: playlistItem)

        #expect(
            requested.map(\.song.videoId) == ["queue-menu-2"],
            "the popover must be for the row that was clicked, not for the song that is playing"
        )
    }

    // MARK: - The popover the row actually opens

    /// The whole path, driven: a right click on a real row of the panel's real table, the menu AppKit
    /// gets from it, the item's action, and the popover's own request for the song.
    ///
    /// The coordinator-level test above states what the item asks for; this one states that the panel
    /// builds a popover from it and that the popover then asks YouTube Music about *that* row's song. A
    /// request for the playing song here would be the bug the reader reported — the popover carrying the
    /// playhead instead of the row.
    @Test("A row's Add to Playlist popover loads that row's song, beside that row")
    func addToPlaylistPopoverLoadsTheClickedRow() async throws {
        let client = MockYTMusicClient()
        client.addToPlaylistEntries = [
            AddToPlaylistEntry(
                id: "VLone",
                title: "One",
                subtitle: nil,
                thumbnailURL: nil,
                canAddVideo: true,
                canRemoveVideoById: true,
                containsVideo: false
            ),
        ]
        let player = PlayerService()
        let songs = TestFixtures.makeSongs(count: 12)
        player.queue = songs
        player.currentIndex = 0
        player.currentTrack = songs[0]

        let hosting = NSHostingView(
            rootView: QueueSidePanelView()
                .environment(player)
                .environment(SongLikeStatusManager.shared)
                .environment(LibraryViewModel(client: client))
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 420)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)

        let builtTable = await self.table(in: hosting)
        let table = try #require(builtTable, "the panel must build its queue table")
        let row = 1
        #expect(table.numberOfRows == songs.count)
        #expect(table.rect(ofRow: row).isEmpty == false)

        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: table.convert(NSPoint(x: 40, y: table.rect(ofRow: row).midY), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let menu = try #require(table.menu(for: event), "a right click on a row opens its menu")
        let item = menu.indexOfItem(withTitle: "Add to Playlist")
        #expect(item >= 0, "the row's menu must offer Add to Playlist")
        menu.performActionForItem(at: item)

        // The popover loads what it was opened for; that request is the proof that the row, and not the
        // playhead, travelled all the way from the click.
        for _ in 0 ..< 200 where client.getAddToPlaylistEntriesVideoIds.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(client.getAddToPlaylistEntriesVideoIds == [songs[row].videoId])

        // And it is open beside that row, not at the list's middle: row 1 of twelve is near the top.
        let popoverWindow = try #require(
            NSApp.windows.first { window in
                window.isVisible && String(describing: type(of: window)).lowercased().contains("popover")
            },
            "Add to Playlist must open a popover"
        )
        let rowOnScreen = window.convertToScreen(table.convert(table.rect(ofRow: row), to: nil))
        #expect(
            abs(popoverWindow.frame.midY - rowOnScreen.midY) < 80,
            "the popover sits beside row \(row) at y=\(rowOnScreen.midY), not at the list's centre"
        )
    }

    /// The panel's table, once SwiftUI has built and laid it out.
    private func table(in hosting: NSView) async -> NSTableView? {
        for _ in 0 ..< 100 {
            if let table = QueueSidePanelMenuTests.descendants(of: hosting).compactMap({ $0 as? NSTableView }).first {
                return table
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private static func descendants(of root: NSView) -> [NSView] {
        var result: [NSView] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            result.append(view)
            stack.append(contentsOf: view.subviews)
        }
        return result
    }

    @Test("Add to Library on a queue row writes the library without starting the song")
    func addToLibraryDoesNotStartPlayback() async throws {
        let client = MockYTMusicClient()
        var song = TestFixtures.makeSong(id: "video-1", title: "Song 1")
        song.feedbackTokens = FeedbackTokens(add: "add-token", remove: nil)
        client.songResponses["video-1"] = song
        let player = PlayerService()
        let coordinator = QueueListControllerRepresentable.Coordinator(
            queue: [song],
            currentIndex: 0,
            isPlaying: false,
            onSelect: { _ in },
            onReorder: { _, _ in nil },
            onRemove: { _ in },
            onStartRadio: { _ in },
            playerService: player,
            client: client,
            likeStatusManager: nil,
            libraryViewModel: nil,
            onOpen: { _ in }
        )

        let menu = try #require(coordinator.menu(forRow: 0))
        let libraryItem = menu.indexOfItem(withTitle: "Add to Library")
        #expect(libraryItem >= 0, "the row's menu must offer Add to Library")
        menu.performActionForItem(at: libraryItem)

        // The write runs off the menu's turn, so the test waits for it rather than sleeping a guess.
        for _ in 0 ..< 100 where client.editSongLibraryStatusTokens.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(client.editSongLibraryStatusTokens == [["add-token"]])
        #expect(player.currentTrack == nil, "Add to Library must leave the playhead where it is")
        #expect(player.queue.isEmpty)
    }
}
