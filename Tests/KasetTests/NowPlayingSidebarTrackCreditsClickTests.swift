import AppKit
import SwiftUI
import Testing

@testable import Kaset

/// What a click on the Now Playing column's title and artist line reaches.
///
/// These are plain buttons drawn outside the page's navigation stack, so there are two things offscreen
/// testing can miss: whether the click lands at all (a 13pt line of names is a target a few points tall
/// without padding) and which of several names it lands on. The title's button is the row's whole width,
/// so a truncated title is still one target. A song can credit one artist or several, and the click must
/// open the name under the pointer — the album header lost a release to a row that handed one click to
/// every link in it (ADR-0023).
@MainActor
@Suite(.serialized)
struct NowPlayingSidebarTrackCreditsClickTests {
    /// What the credit row asked the window to open.
    @Observable
    final class RouteRecorder {
        var routes: [DetailNavigationRoute] = []
    }

    private static let width: CGFloat = 350
    private static let height: CGFloat = 120

    private func song() -> Song {
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

    /// The credit row at the column's width, pinned to the top of its window, so the points below are
    /// the same band the column draws it in.
    private func host(_ recorder: RouteRecorder) -> NSWindow {
        let root = NowPlayingSidebarTrackCredits(
            title: "A Song",
            credits: NowPlayingSidebarCredits(song: self.song(), isPodcast: false),
            onOpen: { recorder.routes.append($0) }
        )
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.height)
        hosting.layoutSubtreeIfNeeded()

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        // A press needs a window; the reader does not need to see it.
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.orderBack(nil)
        self.pump()
        return window
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
        self.pump()
    }

    /// Runs the run loop long enough for SwiftUI to deliver the press.
    ///
    /// Kept short: this pump re-enters the main run loop, and every other `@MainActor` test in the
    /// target shares that actor.
    private func pump() {
        let deadline = Date().addingTimeInterval(0.12)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
    }

    /// The width the drawn text takes at the size the row states.
    private func width(_ text: String, size: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
    }

    /// The title's row, from the top of the window, and the artist line under it: 17pt of title, the
    /// stack's 3pt spacing, then the 13pt names with their hitbox padding.
    private static let titleMidY: CGFloat = Self.height - 11
    private static let artistMidY: CGFloat = Self.height - 33


    @Test("The title is clickable across its whole row, not only on its glyphs")
    func titleHitboxIsTheRow() {
        let recorder = RouteRecorder()
        let window = self.host(recorder)

        // Far past the end of "A Song", inside the row the title is drawn in.
        self.click(in: window, at: NSPoint(x: Self.width - 20, y: Self.titleMidY))

        #expect(recorder.routes.count == 1)
        guard case let .album(playlist) = recorder.routes.first else {
            Issue.record("the title opened \(String(describing: recorder.routes.first))")
            return
        }
        #expect(playlist.id == "MPREb_album")
    }

    @Test("The clicked artist is the one that opens, not the last of them")
    func eachArtistNameOpensItsOwnPage() {
        let recorder = RouteRecorder()
        let window = self.host(recorder)

        let first = self.width("One", size: 13)
        let separator = self.width(", ", size: 13)
        let second = self.width("Two", size: 13)
        self.click(in: window, at: NSPoint(x: first + separator + second / 2, y: Self.artistMidY))

        #expect(recorder.routes.count == 1)
        guard case let .artist(artist) = recorder.routes.first else {
            Issue.record("an artist name opened \(String(describing: recorder.routes.first))")
            return
        }
        #expect(artist.id == "UCtwo")
    }

    @Test("An artist name's target reaches past its glyphs")
    func artistHitboxIsTallerThanTheLine() {
        let recorder = RouteRecorder()
        let window = self.host(recorder)
        let x = self.width("One", size: 13) / 2

        // A 13pt line is about 16pt of text. These points sit outside that text: in the hitbox padding
        // the label adds above and below it (4pt each side).
        for y in [Self.artistMidY + 6, Self.artistMidY - 6] {
            recorder.routes.removeAll()
            self.click(in: window, at: NSPoint(x: x, y: y))
            #expect(recorder.routes.count == 1, "the target misses the name below/above its glyphs at y=\(y)")
            guard case let .artist(artist) = recorder.routes.first else {
                Issue.record("the click at y=\(y) reached \(String(describing: recorder.routes.first))")
                return
            }
            #expect(artist.id == "UCone")
        }
    }
}
