import Foundation
import Testing
@testable import Kaset

/// The queue is two queues in one list, Spotify-style: the songs the playlist/album loaded, and the
/// songs the reader added by hand. Hand-queued songs play first, in the order they were added, and the
/// playlist resumes after them.
@Suite(.serialized, .tags(.service))
@MainActor
struct ManualQueueOrderTests {
    var playerService: PlayerService

    init() {
        self.playerService = PlayerService()
        self.playerService.confirmPlaybackStarted()
    }

    private func startPlaylist() async {
        await self.playerService.playQueue(TestFixtures.makeSongs(count: 4), startingAt: 0)
    }

    private func handQueued(_ id: String) -> Song {
        TestFixtures.makeSong(id: id, title: id)
    }

    private func videoIds() -> [String] {
        self.playerService.queue.map(\.videoId)
    }

    @Test("Add to Queue puts the song under the playing row, above the playlist")
    func addToQueueLandsUnderThePlayingRow() async {
        await self.startPlaylist()

        self.playerService.appendToQueue([self.handQueued("held-1")])

        #expect(self.videoIds() == ["video-0", "held-1", "video-1", "video-2", "video-3"])
        #expect(self.playerService.currentIndex == 0)
    }

    @Test("A second Add to Queue lands below the first and above the playlist")
    func secondAddLandsBelowTheFirst() async {
        await self.startPlaylist()

        self.playerService.appendToQueue([self.handQueued("held-1")])
        self.playerService.appendToQueue([self.handQueued("held-2")])

        #expect(self.videoIds() == ["video-0", "held-1", "held-2", "video-1", "video-2", "video-3"])
    }

    @Test("Play Next goes above rows already added to the queue")
    func playNextGoesAboveHandQueuedRows() async {
        await self.startPlaylist()

        self.playerService.appendToQueue([self.handQueued("held-1")])
        self.playerService.insertNextInQueue([self.handQueued("next-1")])

        #expect(self.videoIds() == ["video-0", "next-1", "held-1", "video-1", "video-2", "video-3"])
    }

    @Test("Rows already added to the queue come before the playlist, in add order")
    func handQueuedRowsPlayBeforeThePlaylist() async {
        await self.startPlaylist()

        self.playerService.appendToQueue([self.handQueued("held-1")])
        self.playerService.appendToQueue([self.handQueued("held-2")])

        await self.playerService.next()
        #expect(self.playerService.currentTrack?.videoId == "held-1")

        await self.playerService.next()
        #expect(self.playerService.currentTrack?.videoId == "held-2")

        await self.playerService.next()
        #expect(self.playerService.currentTrack?.videoId == "video-1")
    }

    @Test("After a hand-queued song has played, a new add still lands above the playlist")
    func addAfterAdvancingStaysAboveThePlaylist() async {
        await self.startPlaylist()

        self.playerService.appendToQueue([self.handQueued("held-1")])
        self.playerService.appendToQueue([self.handQueued("held-2")])

        await self.playerService.next()
        #expect(self.playerService.currentTrack?.videoId == "held-1")

        self.playerService.appendToQueue([self.handQueued("held-3")])

        // held-2 is still ahead, so held-3 goes below it and above the playlist's video-1.
        #expect(self.videoIds() == ["video-0", "held-1", "held-2", "held-3", "video-1", "video-2", "video-3"])
    }

    @Test("Removing a hand-queued song keeps later adds below the ones that remain")
    func removingHandQueuedSongKeepsTheRunCoherent() async {
        await self.startPlaylist()

        self.playerService.appendToQueue([self.handQueued("held-1")])
        self.playerService.appendToQueue([self.handQueued("held-2")])
        self.playerService.removeFromQueue(videoIds: ["held-1"])

        self.playerService.appendToQueue([self.handQueued("held-3")])

        #expect(self.videoIds() == ["video-0", "held-2", "held-3", "video-1", "video-2", "video-3"])
    }

    @Test("Jumping past the hand-queued rows puts the next add under the row picked")
    func jumpingPastTheRunPlacesTheNextAddUnderThePickedRow() async {
        await self.startPlaylist()
        self.playerService.appendToQueue([self.handQueued("held-1")])
        self.playerService.appendToQueue([self.handQueued("held-2")])

        // Pick video-1 from the playlist, skipping both hand-queued rows.
        await self.playerService.playFromQueue(at: 3)
        #expect(self.playerService.currentTrack?.videoId == "video-1")

        self.playerService.appendToQueue([self.handQueued("held-3")])

        #expect(self.videoIds() == ["video-0", "held-1", "held-2", "video-1", "held-3", "video-2", "video-3"])
    }

    @Test("Reordering rows within the hand-queued run keeps them hand-queued")
    func reorderingWithinTheRunKeepsIt() async {
        await self.startPlaylist()
        self.playerService.appendToQueue([self.handQueued("held-1")])
        self.playerService.appendToQueue([self.handQueued("held-2")])
        self.playerService.appendToQueue([self.handQueued("held-3")])
        // [video-0, held-1, held-2, held-3, video-1, video-2, video-3]

        // Drag held-3 above held-1: the row lands where it is released, and the run is still three rows
        // long, so all three stay hand-queued.
        self.playerService.reorderQueue(from: IndexSet(integer: 3), to: 1)

        #expect(self.videoIds() ==
            ["video-0", "held-3", "held-1", "held-2", "video-1", "video-2", "video-3"])
        #expect(self.playerService.manualQueueRange.count == 3)

        self.playerService.appendToQueue([self.handQueued("held-4")])

        #expect(self.videoIds() ==
            ["video-0", "held-3", "held-1", "held-2", "held-4", "video-1", "video-2", "video-3"])
    }

    @Test("A hand-queued row dragged below the run leaves it, and a playlist row takes its place")
    func draggingARowBelowTheRunLeavesIt() async {
        await self.startPlaylist()
        self.playerService.appendToQueue([self.handQueued("held-1")])
        self.playerService.appendToQueue([self.handQueued("held-2")])
        // [video-0, held-1, held-2, video-1, video-2, video-3]

        self.playerService.reorderQueue(from: IndexSet(integer: 1), to: 5)

        // It lands below both playlist rows, and the run is still the two rows under video-0 — which is
        // why video-1 moved up into it.
        #expect(self.videoIds() == ["video-0", "held-2", "video-1", "video-2", "held-1", "video-3"])
        #expect(self.playerService.manualQueueRange.count == 2)
    }

    @Test("A row dropped into the gap under itself changes nothing")
    func aNoOpDropChangesNothing() async {
        await self.startPlaylist()
        self.playerService.appendToQueue([self.handQueued("held-1")])
        // [video-0, held-1, video-1, video-2, video-3]

        // The gap under the run is the first playlist row's own slot, so this moves nothing: the row
        // stays hand-queued and the queue holds still instead of re-filing anything.
        self.playerService.reorderQueue(from: IndexSet(integer: 1), to: 2)

        #expect(self.videoIds() == ["video-0", "held-1", "video-1", "video-2", "video-3"])
        #expect(self.playerService.manualQueueRange.count == 1)
    }

    @Test("The run is the rows under the playing row, so a drop files a row by where it lands")
    func theRunIsTheRowsUnderThePlayingRow() async {
        await self.startPlaylist()
        self.playerService.appendToQueue([self.handQueued("held-1")])
        self.playerService.appendToQueue([self.handQueued("held-2")])
        // [video-0, held-1, held-2, video-1, video-2, video-3]

        // video-2 into the run's last slot: the run is two rows long, so video-2 is hand-queued now and
        // held-2, pushed out, is the playlist's first row.
        self.playerService.reorderQueue(from: IndexSet(integer: 4), to: 2)

        #expect(self.videoIds() == ["video-0", "held-1", "video-2", "held-2", "video-1", "video-3"])
        #expect(self.playerService.manualQueueRange.count == 2)

        // A new add still lands at the run's end, below video-2 and above held-2.
        self.playerService.appendToQueue([self.handQueued("held-3")])
        #expect(self.videoIds() ==
            ["video-0", "held-1", "video-2", "held-3", "held-2", "video-1", "video-3"])
    }

    @Test("A playlist row dragged above a hand-queued row joins the run")
    func draggingAPlaylistRowIntoTheRunJoinsIt() async {
        await self.startPlaylist()
        self.playerService.appendToQueue([self.handQueued("held-1")])
        // [video-0, held-1, video-1, video-2, video-3]

        // Drag video-2 (a playlist row) above held-1, which is where the run begins.
        self.playerService.reorderQueue(from: IndexSet(integer: 3), to: 1)

        // The run is one row long, so video-2 is hand-queued now and held-1, pushed out, is the
        // playlist's first row.
        #expect(self.videoIds() == ["video-0", "video-2", "held-1", "video-1", "video-3"])
        #expect(self.playerService.manualQueueRange.count == 1)

        self.playerService.appendToQueue([self.handQueued("held-2")])
        #expect(self.videoIds() == ["video-0", "video-2", "held-2", "held-1", "video-1", "video-3"])
    }

    @Test("Reordering the playlist's own rows at the section boundary keeps them in the playlist")
    func reorderingPlaylistRowsAtTheBoundaryStaysInThePlaylist() async {
        await self.startPlaylist()
        self.playerService.appendToQueue([self.handQueued("held-1")])
        self.playerService.appendToQueue([self.handQueued("held-2")])
        // [video-0, held-1, held-2, video-1, video-2, video-3]

        // Drag video-2 above video-1: the row lands where it is released, and the run is two rows long,
        // so both stay in the playlist.
        self.playerService.reorderQueue(from: IndexSet(integer: 4), to: 3)

        #expect(self.videoIds() == ["video-0", "held-1", "held-2", "video-2", "video-1", "video-3"])
        #expect(self.playerService.manualQueueRange.count == 2)

        // The next add still lands below the hand-queued rows and above the playlist.
        self.playerService.appendToQueue([self.handQueued("held-3")])
        #expect(self.videoIds() ==
            ["video-0", "held-1", "held-2", "held-3", "video-2", "video-1", "video-3"])
    }

    @Test("A dragged row lands exactly where it is released, in either direction")
    func aDropLandsWhereItIsReleased() async {
        await self.startPlaylist()
        self.playerService.appendToQueue([self.handQueued("held-1")])
        self.playerService.appendToQueue([self.handQueued("held-2")])
        // [video-0, held-1, held-2, video-1, video-2, video-3]

        self.playerService.reorderQueue(from: IndexSet(integer: 2), to: 1)
        #expect(self.videoIds() == ["video-0", "held-2", "held-1", "video-1", "video-2", "video-3"])

        // A playlist row lifted to the top of the run, with no section to ask about.
        self.playerService.reorderQueue(from: IndexSet(integer: 4), to: 1)
        #expect(self.videoIds() == ["video-0", "video-2", "held-2", "held-1", "video-1", "video-3"])
    }

    @Test("A hand-queued row dragged below the run leaves it")
    func draggingAHandQueuedRowBelowTheRunLeavesIt() async {
        await self.startPlaylist()
        self.playerService.appendToQueue([self.handQueued("held-1")])
        self.playerService.appendToQueue([self.handQueued("held-2")])
        // [video-0, held-1, held-2, video-1, video-2, video-3]

        // Drag held-1 below held-2 and the first playlist row: it is the playlist's second row now,
        // and video-1, which the run needs to stay two rows long, is hand-queued.
        self.playerService.reorderQueue(from: IndexSet(integer: 1), to: 4)

        #expect(self.videoIds() == ["video-0", "held-2", "video-1", "held-1", "video-2", "video-3"])
        #expect(self.playerService.manualQueueRange.count == 2)

        self.playerService.appendToQueue([self.handQueued("held-3")])
        #expect(self.videoIds() ==
            ["video-0", "held-2", "video-1", "held-3", "held-1", "video-2", "video-3"])
    }

    @Test("A playlist row dropped above the run pushes its last row out")
    func aPlaylistRowDroppedAboveTheRunPushesItsLastRowOut() async {
        await self.startPlaylist()
        self.playerService.appendToQueue([self.handQueued("held-1")])
        // [video-0, held-1, video-1, video-2, video-3]

        self.playerService.reorderQueue(from: IndexSet(integer: 4), to: 1)

        #expect(self.videoIds() == ["video-0", "video-3", "held-1", "video-1", "video-2"])
        #expect(self.playerService.manualQueueRange.count == 1)
    }

    @Test("Clearing the run removes the hand-queued songs and leaves the playlist")
    func clearingTheRunLeavesThePlaylist() async {
        await self.startPlaylist()
        self.playerService.appendToQueue([self.handQueued("held-1")])
        self.playerService.appendToQueue([self.handQueued("held-2")])

        self.playerService.clearManualQueue()

        #expect(self.videoIds() == ["video-0", "video-1", "video-2", "video-3"])
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.manualQueueRange.isEmpty)

        // Undo brings them back as hand-queued rows.
        self.playerService.undoQueue()
        #expect(self.videoIds() == ["video-0", "held-1", "held-2", "video-1", "video-2", "video-3"])
        #expect(self.playerService.manualQueueRange.count == 2)
    }

    @Test("Clearing an empty run does nothing")
    func clearingAnEmptyRunDoesNothing() async {
        await self.startPlaylist()
        let queueBefore = self.videoIds()

        self.playerService.clearManualQueue()

        #expect(self.videoIds() == queueBefore)
        #expect(self.playerService.manualQueueRange.isEmpty)
    }

    @Test("A new playlist clears the rows added to the queue")
    func newPlaylistClearsTheHandQueuedRun() async {
        await self.startPlaylist()
        self.playerService.appendToQueue([self.handQueued("held-1")])

        let otherPlaylist = [
            TestFixtures.makeSong(id: "other-0", title: "Other 0"),
            TestFixtures.makeSong(id: "other-1", title: "Other 1"),
        ]
        await self.playerService.playQueue(otherPlaylist, startingAt: 0)

        self.playerService.appendToQueue([self.handQueued("held-2")])

        #expect(self.videoIds() == ["other-0", "held-2", "other-1"])
    }

    @Test("Undo and redo put the hand-queued run back with the queue")
    func undoAndRedoCarryTheRun() async {
        await self.startPlaylist()
        self.playerService.appendToQueue([self.handQueued("held-1")])

        self.playerService.undoQueue()
        #expect(self.videoIds() == ["video-0", "video-1", "video-2", "video-3"])

        self.playerService.redoQueue()
        #expect(self.videoIds() == ["video-0", "held-1", "video-1", "video-2", "video-3"])

        // The restored queue still knows held-1 was added by hand.
        self.playerService.appendToQueue([self.handQueued("held-2")])
        #expect(self.videoIds() == ["video-0", "held-1", "held-2", "video-1", "video-2", "video-3"])
    }

    @Test("Add to Queue on an empty queue is just the queue")
    func addToEmptyQueue() async {
        #expect(self.playerService.queue.isEmpty)

        self.playerService.appendToQueue([self.handQueued("held-1")])

        #expect(self.videoIds() == ["held-1"])
        #expect(self.playerService.currentIndex == 0)
    }
}
