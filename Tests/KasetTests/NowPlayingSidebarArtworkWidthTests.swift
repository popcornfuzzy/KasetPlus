import AppKit
import SwiftUI
import Testing

@testable import Kaset

/// The Now Playing column's artwork, and the width it may not take.
///
/// A `.resizable()` image with `aspectRatio(contentMode: .fill)` in a stack reports its *filled* width as
/// the smallest the slot may be. A 16:9 cover in the column's 300pt-tall artwork slot measured 534pt wide,
/// and the column took that width: the media, the title block and both cards were laid out 534 wide in a
/// 300pt column and drawn past the window's right edge — "the whole sidebar goes past the right edge with
/// everything with it", reported on a VEVO video (whose cover is 16:9) in a 300pt column.
///
/// The cover is therefore drawn as an overlay on a flexible color (`NowPlayingSidebarArtwork.artwork`), and
/// the media slot states the column's width (`NowPlayingSidebarView.mediaSection`) — so nothing the cover
/// asks for can become the column's own width.
///
/// The cover comes from a file, not the network: the same filled-width rule only shows once an image is
/// there, and a test must not depend on YouTube answering.
@MainActor
@Suite(.serialized)
struct NowPlayingSidebarArtworkWidthTests {
    /// The column at its floor: the width the report was made at.
    private static let columnWidth: CGFloat = 300
    private static let columnHeight: CGFloat = 636

    private func emit(_ message: String) {
        DiagnosticsLogger.ui.debug("\(message, privacy: .public)")
    }

    private func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// A 16:9 cover on disk, so the column can be handed a wide one without a request.
    private func wideCover() throws -> URL {
        let size = CGSize(width: 640, height: 360)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        let tiff = try #require(image.tiffRepresentation, "the cover could not be drawn")
        let bitmap = try #require(NSBitmapImageRep(data: tiff), "the cover could not be read back")
        let png = try #require(bitmap.representation(using: .png, properties: [:]), "the cover could not be encoded")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kaset-sidebar-width-cover.png")
        try png.write(to: url)
        return url
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scroll = view as? NSScrollView { found.append(scroll) }
        for sub in view.subviews { found.append(contentsOf: self.scrollViews(in: sub)) }
        return found
    }

    @Test("A wide cover cannot widen the column")
    func wideCoverDoesNotWidenTheColumn() async throws {
        let settings = SettingsManager.shared
        let lyrics = settings.syncedLyricsEnabled
        let canvas = settings.animatedCanvasEnabled
        defer {
            settings.syncedLyricsEnabled = lyrics
            settings.animatedCanvasEnabled = canvas
        }
        // The column searches lyrics and canvas for whatever is playing; neither belongs in this test.
        settings.syncedLyricsEnabled = false
        settings.animatedCanvasEnabled = false

        let cover = try self.wideCover()
        // Warm the decode first: the filled width is what the test is about, and a column that has not laid
        // out the cover yet has no width to take.
        let loaded = await ImageCache.shared.image(
            for: cover,
            targetSize: CGSize(width: 520, height: 520)
        )
        #expect(loaded != nil, "the test's own cover did not load")

        var song = Song(
            id: "video-1",
            title: "Jonas Blue - By Your Side ft. RAYE (Official Video)",
            artists: [
                Artist(id: "UCone", name: "Jonas Blue"),
                Artist(id: "UCtwo", name: "RAYE"),
            ],
            album: nil,
            duration: 212,
            thumbnailURL: cover,
            videoId: "video-1"
        )
        song.hasVideo = true
        song.musicVideoType = .omv

        let player = PlayerService()
        player.setNowPlayingSidebarPage(.overview)
        player.queue = [song]
        player.currentIndex = 0
        player.currentTrack = song

        let column = NowPlayingSidebarView(
            columnWidth: Self.columnWidth,
            columnHeight: Self.columnHeight,
            topInset: 52
        )
        .environment(player)
        .environment(SyncedLyricsService())
        .environment(CanvasService())
        .environment(PodcastTranscriptService(client: MockYTMusicClient()))

        let hosting = NSHostingView(rootView: column)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.columnWidth, height: Self.columnHeight)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        // Fully transparent: a test has no business putting a window on the reader's desktop.
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        self.pump(1.5)
        hosting.layoutSubtreeIfNeeded()

        // The overview scrolls; its content is where the column's real width is stated.
        let scroll = try #require(self.scrollViews(in: hosting).first, "the column has no overview scroll view")
        let documentWidth = try #require(scroll.documentView?.frame.width)
        #expect(
            documentWidth <= Self.columnWidth + 0.5,
            "the overview is \(documentWidth) wide in a \(Self.columnWidth)pt column"
        )

        // And what is drawn: a card or a cover that is laid out past the column is the reader's bug.
        let layer = try #require(hosting.layer, "the column is not layer-backed")
        let probeWidth = 1200
        let probeHeight = Int(Self.columnHeight)
        let context = try #require(CGContext(
            data: nil,
            width: probeWidth,
            height: probeHeight,
            bitsPerComponent: 8,
            bytesPerRow: probeWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        layer.render(in: context)
        let data = try #require(context.data)
        let bytes = data.bindMemory(to: UInt8.self, capacity: probeWidth * probeHeight * 4)

        var maxX = -1
        for y in 0..<probeHeight {
            for x in 0..<probeWidth where bytes[(y * probeWidth + x) * 4 + 3] > 8 {
                if x > maxX { maxX = x }
            }
        }
        #expect(
            maxX <= Int(Self.columnWidth),
            "the column draws to x=\(maxX) in a \(Int(Self.columnWidth))pt column"
        )
        self.emit("Sidebar column ink: maxX=\(maxX) width=\(Int(Self.columnWidth)) document=\(Int(documentWidth))")
    }
}
