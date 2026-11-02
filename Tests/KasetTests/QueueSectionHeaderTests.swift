import AppKit
import Testing
@testable import Kaset

/// The queue's two sections: rows the reader added by hand ("Next in queue") and the playlist's own
/// remaining songs ("Rest of the queue"), drawn the way Spotify's queue draws them.
///
/// A caption is a **row of its own** (an AppKit group row), so it can never be dragged, selected, or
/// appear in a drag image. Every other row maps back to its queue index, and these tests state that
/// mapping on the coordinator the table asks.
@Suite(.serialized)
@MainActor
struct QueueSectionHeaderTests {
    private func makeCoordinator(
        queue: [Song],
        currentIndex: Int,
        manualQueueCount: Int
    ) -> QueueListControllerRepresentable.Coordinator {
        QueueListControllerRepresentable.Coordinator(
            queue: queue,
            currentIndex: currentIndex,
            manualQueueCount: manualQueueCount,
            isPlaying: false,
            favoritesManager: FavoritesManager(skipLoad: true),
            onSelect: { _ in },
            onReorder: { _, _ in nil },
            onRemove: { _ in },
            onStartRadio: { _ in }
        )
    }

    private func makeTable() -> NSTableView {
        NSTableView(frame: NSRect(x: 0, y: 0, width: 350, height: 400))
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField { found.append(field) }
        for subview in view.subviews {
            found.append(contentsOf: self.textFields(in: subview))
        }
        return found
    }

    private func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton { found.append(button) }
        for subview in view.subviews {
            found.append(contentsOf: self.buttons(in: subview))
        }
        return found
    }

    @Test("Captions are rows of their own, above the songs of each section")
    func captionsAreRowsAboveTheirSongs() {
        let coordinator = self.makeCoordinator(
            queue: TestFixtures.makeSongs(count: 5),
            currentIndex: 0,
            manualQueueCount: 2
        )

        // Songs 1–2 are hand-queued, 3–4 are the playlist's remaining songs.
        #expect(coordinator.rows.count == 7)
        #expect(coordinator.isSectionHeaderRow(0) == false)
        #expect(coordinator.isSectionHeaderRow(1))
        #expect(coordinator.isSectionHeaderRow(2) == false)
        #expect(coordinator.isSectionHeaderRow(3) == false)
        #expect(coordinator.isSectionHeaderRow(4))
        #expect(coordinator.isSectionHeaderRow(5) == false)
        #expect(coordinator.isSectionHeaderRow(6) == false)

        #expect(coordinator.queueIndex(forTableRow: 0) == 0)
        #expect(coordinator.queueIndex(forTableRow: 1) == nil)
        #expect(coordinator.queueIndex(forTableRow: 2) == 1)
        #expect(coordinator.queueIndex(forTableRow: 3) == 2)
        #expect(coordinator.queueIndex(forTableRow: 4) == nil)
        #expect(coordinator.queueIndex(forTableRow: 5) == 3)
        #expect(coordinator.queueIndex(forTableRow: 6) == 4)

        #expect(coordinator.tableRow(forQueueIndex: 0) == 0)
        #expect(coordinator.tableRow(forQueueIndex: 1) == 2)
        #expect(coordinator.tableRow(forQueueIndex: 2) == 3)
        #expect(coordinator.tableRow(forQueueIndex: 3) == 5)
        #expect(coordinator.tableRow(forQueueIndex: 4) == 6)
    }

    @Test("A queue without hand-queued rows has no sections")
    func plainQueueHasNoSections() {
        let coordinator = self.makeCoordinator(
            queue: TestFixtures.makeSongs(count: 4),
            currentIndex: 0,
            manualQueueCount: 0
        )

        #expect(coordinator.rows.count == 4)
        #expect((0 ..< 4).allSatisfy { coordinator.isSectionHeaderRow($0) == false })
        #expect((0 ..< 4).allSatisfy { coordinator.tableRow(forQueueIndex: $0) == $0 })
    }

    @Test("A run that reaches the end of the queue has no playlist section below it")
    func runAtTheEndHasOneCaption() {
        let coordinator = self.makeCoordinator(
            queue: TestFixtures.makeSongs(count: 3),
            currentIndex: 0,
            manualQueueCount: 2
        )

        #expect(coordinator.rows.count == 4)
        #expect((0 ..< 4).filter { coordinator.isSectionHeaderRow($0) } == [1])
    }

    @Test("Captions are group rows, and their rows are shorter than a song's")
    func captionsAreGroupRows() {
        let coordinator = self.makeCoordinator(
            queue: TestFixtures.makeSongs(count: 5),
            currentIndex: 0,
            manualQueueCount: 2
        )
        let table = self.makeTable()

        #expect(coordinator.tableView(table, heightOfRow: 0) == QueueTableCellView.rowHeight)
        #expect(coordinator.tableView(table, heightOfRow: 1) == QueueSectionHeaderCellView.rowHeight)
        #expect(coordinator.tableView(table, isGroupRow: 0) == false)
        #expect(coordinator.tableView(table, isGroupRow: 1))
        #expect(coordinator.tableView(table, isGroupRow: 4))
        #expect(coordinator.tableView(table, isGroupRow: 5) == false)
    }

    @Test("A caption offers no drag, and a song's drag carries its queue index")
    func captionsCannotBeDragged() {
        let coordinator = self.makeCoordinator(
            queue: TestFixtures.makeSongs(count: 5),
            currentIndex: 0,
            manualQueueCount: 2
        )
        let table = self.makeTable()

        // Row 1 is the "Next in queue" caption, row 2 is the first hand-queued song (queue index 1).
        #expect(coordinator.tableView(table, pasteboardWriterForRow: 1) == nil)
        #expect(coordinator.isDragging == false)

        let writer = coordinator.tableView(table, pasteboardWriterForRow: 2)
        let item = writer as? NSPasteboardItem
        let payload = item?.string(forType: NSPasteboard.PasteboardType("com.kaset.queueitem"))
        #expect(payload == "1")
    }

    @Test("A drop lands on a queue index, skipping the caption rows")
    func dropDestinationSkipsCaptions() {
        let coordinator = self.makeCoordinator(
            queue: TestFixtures.makeSongs(count: 5),
            currentIndex: 0,
            manualQueueCount: 2
        )

        // Rows: song0, caption, song1, song2, caption, song3, song4.
        #expect(coordinator.queueDestination(forTableRow: 0) == 0)
        // Above the "Next in queue" caption is still after the playing row: the caption follows the row
        // that opens its section, so the new row simply becomes the first hand-queued song.
        #expect(coordinator.queueDestination(forTableRow: 1) == 1)
        #expect(coordinator.queueDestination(forTableRow: 2) == 1)
        #expect(coordinator.queueDestination(forTableRow: 3) == 2)
        #expect(coordinator.queueDestination(forTableRow: 4) == 3)
        #expect(coordinator.queueDestination(forTableRow: 5) == 3)
        #expect(coordinator.queueDestination(forTableRow: 7) == 5)
    }

    @Test("Only the hand-queued section's caption carries a clear button")
    func clearButtonBelongsToTheRun() {
        let header = QueueSectionHeaderCellView(
            frame: NSRect(x: 0, y: 0, width: 350, height: QueueSectionHeaderCellView.rowHeight)
        )
        var cleared = false

        header.configure(title: "Next in queue", clearsHandQueuedSongs: true, onClear: { cleared = true })

        guard let button = self.buttons(in: header).first else {
            Issue.record("the section caption has no clear button")
            return
        }
        #expect(button.isHidden == false)
        #expect(self.textFields(in: header).contains { $0.stringValue == "Next in queue" })

        button.performClick(nil)
        #expect(cleared)

        // The other section's caption has no button.
        header.configure(title: "Rest of the queue", clearsHandQueuedSongs: false, onClear: { cleared = true })
        #expect(button.isHidden)
    }

    @Test("The caption lays out inside its row")
    func captionLaysOutInsideTheRow() {
        let header = QueueSectionHeaderCellView(
            frame: NSRect(x: 0, y: 0, width: 350, height: QueueSectionHeaderCellView.rowHeight)
        )
        header.configure(title: "Next in queue", clearsHandQueuedSongs: true, onClear: {})
        header.layoutSubtreeIfNeeded()

        guard let caption = self.textFields(in: header).first(where: { $0.stringValue == "Next in queue" })
        else {
            Issue.record("the row did not draw its caption")
            return
        }

        #expect(caption.frame.height > 0)
        #expect(caption.frame.minY >= 0)
        #expect(caption.frame.maxY <= header.bounds.height)
    }
}
