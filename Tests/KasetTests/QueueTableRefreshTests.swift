import AppKit
import Testing
@testable import Kaset

/// What the queue table does around a drag: it never floats a section caption, it never rebuilds its
/// rows mid-drag, and it installs a drop's new order inside the drop itself.
///
/// All three are drag-time behaviour the reader sees and no scrolling or clicking test can reach. The
/// caption used to be a floating group row, so a drag carried it along with the rows making room; and
/// the table used to reload only after the model's update came back through SwiftUI, which is a beat
/// after AppKit has settled the session — the old order was drawn for a frame, then the new one.
@Suite(.serialized)
@MainActor
struct QueueTableRefreshTests {
    /// Counts the reloads the queue asks for, so a redundant one is visible.
    @available(macOS 26.0, *)
    final class CountingTableView: DraggableTableView {
        private(set) var reloadCount = 0

        override func reloadData() {
            self.reloadCount += 1
            super.reloadData()
        }
    }

    private func makeCoordinator(
        queue: [Song],
        currentIndex: Int = 0,
        manualQueueCount: Int = 0,
        onReorder: @escaping (Int, Int) -> QueueTableState? = { _, _ in nil }
    ) -> QueueListControllerRepresentable.Coordinator {
        QueueListControllerRepresentable.Coordinator(
            queue: queue,
            currentIndex: currentIndex,
            manualQueueCount: manualQueueCount,
            isPlaying: false,
            favoritesManager: FavoritesManager(skipLoad: true),
            onSelect: { _ in },
            onReorder: onReorder,
            onRemove: { _ in },
            onStartRadio: { _ in }
        )
    }

    private func makeTable(
        dataSource: QueueListControllerRepresentable.Coordinator
    ) -> CountingTableView {
        let table = CountingTableView(frame: NSRect(x: 0, y: 0, width: 350, height: 400))
        table.rowHeight = 56
        // The rows live in a column, as they do in the panel.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("QueueColumn"))
        column.width = 350
        table.addTableColumn(column)
        table.delegate = dataSource
        table.dataSource = dataSource
        table.coordinator = dataSource
        table.reloadData()
        return table
    }

    @Test("The queue's section captions never float over the rows")
    func sectionCaptionsDoNotFloat() {
        // A floating group row is drawn above the list and is carried along with the rows a drag makes
        // room for — which is how the caption under the pointer slid around with the song in hand.
        let controller = QueueListControllerRepresentable.QueueListViewController()
        controller.loadView()

        #expect(controller.tableView != nil)
        #expect(controller.tableView?.floatsGroupRows == false)
    }

    @Test("A drop hands the table its new order before the session settles")
    func aDropAppliesTheNewOrderImmediately() {
        let queue = TestFixtures.makeSongs(count: 4)
        var reordered = queue
        reordered.swapAt(2, 3)
        let coordinator = self.makeCoordinator(queue: queue) { _, _ in
            QueueTableState(queue: reordered, currentIndex: 0, manualQueueCount: 0)
        }
        let table = self.makeTable(dataSource: coordinator)

        #expect(coordinator.performDrop(from: 2, to: 3, in: table))

        // The rows the table reads from this moment on are the reordered queue, so the drop's own
        // animation settles onto the final order instead of showing the old one first.
        #expect(coordinator.queue.map(\.videoId) == reordered.map(\.videoId))
        #expect(coordinator.needsReload == false)

        // The SwiftUI update the reorder also produces carries the state the table already shows and
        // must not rebuild every row a beat after the drop.
        let reloads = table.reloadCount
        coordinator.apply(queue: reordered, currentIndex: 0, manualQueueCount: 0)
        coordinator.reloadIfNeeded(in: table)
        #expect(table.reloadCount == reloads)
    }

    @Test("A change that arrives mid-drag is applied when the drag ends")
    func aMidDragChangeWaitsForTheDrag() {
        let queue = TestFixtures.makeSongs(count: 4)
        let coordinator = self.makeCoordinator(queue: queue)
        let table = self.makeTable(dataSource: coordinator)
        let reloads = table.reloadCount

        // Mid-drag the table owns its row views: recreating them under the pointer is what made the
        // list rearrange itself while a row was in hand.
        coordinator.isDragging = true
        coordinator.apply(queue: Array(queue.prefix(2)), currentIndex: 0, manualQueueCount: 1)
        coordinator.reloadIfNeeded(in: table)
        #expect(table.reloadCount == reloads)
        #expect(coordinator.needsReload)

        coordinator.isDragging = false
        coordinator.reloadIfNeeded(in: table)
        #expect(table.reloadCount == reloads + 1)
        #expect(coordinator.needsReload == false)
    }

    @Test("A queue the table is not already showing is rebuilt once")
    func aChangedQueueRebuilds() {
        let queue = TestFixtures.makeSongs(count: 4)
        let coordinator = self.makeCoordinator(queue: queue)
        let table = self.makeTable(dataSource: coordinator)
        let reloads = table.reloadCount

        coordinator.apply(queue: queue, currentIndex: 0, manualQueueCount: 2)
        coordinator.reloadIfNeeded(in: table)

        #expect(table.reloadCount == reloads + 1)
        #expect(coordinator.isSectionHeaderRow(1))
    }

    @Test("Every gap is one place: a caption takes no position in the queue")
    func aCaptionTakesNoPositionInTheQueue() {
        // The reader's queue: the playhead on song 8, "Next in queue" holding songs 9 and 10, and the
        // playlist starting at song 11.
        let coordinator = self.makeCoordinator(
            queue: TestFixtures.makeSongs(count: 13), currentIndex: 7, manualQueueCount: 2
        )

        // Rows: 0-7 songs 1-8, 8 the "Next in queue" caption, 9-10 songs 9-10, 11 the "Rest of the
        // queue" caption, 12 the playlist's first row, 13 the playlist's second row.
        #expect(coordinator.tableRow(forQueueIndex: 11) == 13)

        // A drop counts the songs above it, so the gap above the caption and the gap under it are the
        // same destination — one place between two rows, with no section to decide.
        #expect(coordinator.queueDestination(forTableRow: 11) == 10)
        #expect(coordinator.queueDestination(forTableRow: 12) == 10)
    }

    @Test("A drop onto a row's own slot is refused, everywhere in the list")
    func aDropOntoItsOwnSlotIsRefused() {
        let coordinator = self.makeCoordinator(
            queue: TestFixtures.makeSongs(count: 6), currentIndex: 0, manualQueueCount: 2
        )

        // Nothing to move, so nothing to show: refused rather than asking the model for a move of
        // nothing, which would spring back after a flicker.
        for index in 1 ..< 6 {
            #expect(!coordinator.dropIsAllowed(from: index, to: index))
        }
        // The place after it is a position like any other, on either side of the boundary.
        #expect(coordinator.dropIsAllowed(from: 3, to: 4))
        #expect(coordinator.dropIsAllowed(from: 1, to: 4))
        #expect(coordinator.dropIsAllowed(from: 4, to: 1))

        // The playing row is locked.
        #expect(!coordinator.dropIsAllowed(from: 0, to: 3))
    }
}
