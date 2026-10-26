import AppKit
import SwiftUI
import Testing
@testable import Kaset

/// What a click on a sidebar card does, wherever on the card it lands.
///
/// The lyric window and the up-next row are both previews of a page: their header and their content
/// open that page, but the card is the thing the reader sees as one surface, so its padding, its empty
/// space and the gap between the rows in its lyric window must open it too. These tests press the card
/// itself, away from any label inside it.
@Suite(.serialized)
@MainActor
struct NowPlayingSidebarCardTapTests {
    // MARK: - Harness

    /// The card, at the column width the sidebar gives it, with one small label in the top-left.
    private func host(_ recorder: TapRecorder) -> NSWindow {
        self.hostCard(NowPlayingSidebarCard(onTap: { recorder.taps += 1 }) {
            Text("Lyrics")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 50, height: 14, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        })
    }

    /// The card in a column, hosted at the top of it, in a window of its own.
    private func hostCard(_ card: some View) -> NSWindow {
        let root = card
            .padding(.horizontal, NowPlayingSidebarLayout.padding)
            .frame(maxHeight: .infinity, alignment: .top)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.columnWidth, height: Self.columnHeight)
        hosting.layoutSubtreeIfNeeded()

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        // Never ordered: a press needs a window, not one on the desktop. These used to put real windows
        // on the reader's screen — one per hosted test.
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

    /// Runs the run loop long enough for SwiftUI to deliver a gesture.
    private func pump() {
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
    }

    /// The column this card is hosted at, and the points inside it where a press lands: on the card's
    /// empty space, on its padding, and in the column's own gutter outside it.
    private static let columnWidth: CGFloat = 352
    private static let columnHeight: CGFloat = 240
    private static let cardRightEdge = Self.columnWidth - NowPlayingSidebarLayout.padding

    /// The card sits at the top of the column with a 14pt label in it: 10pt of padding, the label's
    /// row, 10pt of padding again. AppKit places the origin bottom-left, so those bands read downwards
    /// from the column's height.
    private static let labelMidY = Self.columnHeight - 17
    private static let bottomPaddingMidY = Self.columnHeight - 30

    // MARK: - Tests

    @Test("A click on the card's empty space opens what the card previews")
    func emptySpaceOpensThePage() {
        let recorder = TapRecorder()
        let window = self.host(recorder)
        defer { window.orderOut(nil) }

        // Right of the label, inside the card: the card's own empty space.
        self.click(in: window, at: NSPoint(x: Self.cardRightEdge - 24, y: Self.labelMidY))
        #expect(recorder.taps == 1, "the card's empty space swallowed the click")
    }

    @Test("A click on the card's padding opens it too")
    func paddingOpensThePage() {
        let recorder = TapRecorder()
        let window = self.host(recorder)
        defer { window.orderOut(nil) }

        // Inside the glass, below the label and clear of the rounded corners: the card's 10pt
        // padding band.
        self.click(in: window, at: NSPoint(x: Self.columnWidth / 2, y: Self.bottomPaddingMidY))
        #expect(recorder.taps == 1, "the card's padding swallowed the click")
    }

    /// The lyric window is a scroll view (`allowsScrolling: false`), and a scroll view is happy to take
    /// a press that lands on its own background and do nothing with it. The card has to hear it too.
    @Test("A click inside the lyric window's scroll view opens the page")
    func scrollViewAreaOpensThePage() {
        let recorder = TapRecorder()
        let window = self.hostCard(NowPlayingSidebarCard(onTap: { recorder.taps += 1 }) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lyrics")
                    .font(.system(size: 11, weight: .semibold))
                ScrollView {
                    Text("One line of lyrics")
                }
                .scrollDisabled(true)
                .frame(height: NowPlayingSidebarLayout.lyricsPreviewHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        })
        defer { window.orderOut(nil) }

        // In the scroll view's empty middle, below the one line it holds.
        self.click(in: window, at: NSPoint(x: Self.columnWidth / 2, y: Self.columnHeight - 90))
        #expect(recorder.taps == 1, "the lyric window's scroll view swallowed the click")
    }

    @Test("A click outside the card does nothing")
    func outsideTheCardIsNotAClick() {
        let recorder = TapRecorder()
        let window = self.host(recorder)
        defer { window.orderOut(nil) }

        // Past the card's right edge, in the column's own padding between the card and its edge.
        self.click(in: window, at: NSPoint(x: Self.columnWidth - 4, y: Self.labelMidY))
        #expect(recorder.taps == 0, "a click in the column's gutter opened the page")
    }
}

// MARK: - Recorder

@MainActor
private final class TapRecorder {
    var taps = 0
}
