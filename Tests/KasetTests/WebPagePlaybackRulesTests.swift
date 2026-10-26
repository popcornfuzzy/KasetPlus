import Foundation
import Testing
@testable import Kaset

/// The rules behind Kaset's in-page track changes: what the page is asked, and what Kaset concludes
/// when the page turns out to be playing something else.
@Suite(.serialized, .tags(.service))
@MainActor
struct WebPagePlaybackRulesTests {
    private func song(_ videoId: String) -> Song {
        Song(
            id: videoId,
            title: "Song \(videoId)",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: videoId
        )
    }

    // MARK: - Settle decisions

    @Test("A page playing the requested track confirms the start")
    func settleConfirmsTheRequestedTrack() {
        let decision = WebQueueSettleRules.decision(
            expectedVideoId: "v2",
            settledVideoId: "v2",
            observedVideoId: "v2",
            reassertionsLeft: 1
        )
        #expect(decision == .confirmed)
    }

    @Test("A page playing another track is asked once more, in place")
    func settleReassertsOnce() {
        let decision = WebQueueSettleRules.decision(
            expectedVideoId: "v2",
            settledVideoId: "v2",
            observedVideoId: "v3",
            reassertionsLeft: 1
        )
        #expect(decision == .reassert)
    }

    @Test("A page that keeps another track is loaded the long way")
    func settleFallsBackToAPageLoad() {
        let decision = WebQueueSettleRules.decision(
            expectedVideoId: "v2",
            settledVideoId: "v2",
            observedVideoId: "v3",
            reassertionsLeft: 0
        )
        #expect(decision == .load)
    }

    @Test("A newer track start settles nothing about the previous one")
    func settleIgnoresAnOldRequest() {
        let decision = WebQueueSettleRules.decision(
            expectedVideoId: "v2",
            settledVideoId: "v3",
            observedVideoId: "v2",
            reassertionsLeft: 1
        )
        #expect(decision == .idle)
    }

    @Test("A page that says nothing settles nothing")
    func settleIgnoresASilentPage() {
        #expect(
            WebQueueSettleRules.decision(
                expectedVideoId: "v2",
                settledVideoId: "v2",
                observedVideoId: nil,
                reassertionsLeft: 1
            ) == .idle
        )
        #expect(
            WebQueueSettleRules.decision(
                expectedVideoId: "v2",
                settledVideoId: "v2",
                observedVideoId: "",
                reassertionsLeft: 1
            ) == .idle
        )
    }

    // MARK: - Bridge statuses

    @Test("Bridge statuses map onto what this document can do")
    func statusesMapOntoCapabilities() {
        let status = WebPagePlaybackStatus.self
        #expect(status.succeeded(status.alreadyPlaying))
        #expect(status.succeeded(status.playedAt))
        #expect(status.succeeded(status.loadedVideo))
        #expect(!status.succeeded(status.noPlayer))
        #expect(!status.succeeded(status.notInstalled))
        #expect(!status.succeeded(status.failed))

        #expect(status.capability(of: status.loadedVideo) == .inPage)
        #expect(status.capability(of: status.noPlayer) == .unavailable)
        #expect(status.capability(of: status.failed) == .unavailable)
    }

    // MARK: - Position and near-end handling

    @Test("Starting a track resets the position, so the old song's end cannot be read twice")
    func startingATrackResetsThePosition() async {
        let service = PlayerService()
        await service.playQueue([self.song("v1"), self.song("v2"), self.song("v3")], startingAt: 0)
        service.progress = 176
        service.duration = 180

        await service.next()

        #expect(service.currentIndex == 1)
        #expect(service.progress == 0)
    }

    @Test("Repeated near-end reports advance the queue only once")
    func nearEndReportsAdvanceOnce() async throws {
        let service = PlayerService()
        await service.playQueue([self.song("v1"), self.song("v2"), self.song("v3")], startingAt: 0)
        service.toggleShuffle() // shuffle has no "expected next" row: the heuristic branch

        // The page reporting the same unexpected track again, as it does several times as the song
        // moves on. Only the first report may advance the queue.
        service.advanceForNearEndTransition()
        let firstAdvance = try #require(service.lastNearEndAdvanceInstant)
        service.advanceForNearEndTransition()
        #expect(service.lastNearEndAdvanceInstant == firstAdvance)

        service.toggleShuffle()
    }

    @Test("The page's leftover advance right after a track starts does not move the queue")
    func leftoverAdvanceRightAfterStartIsRejected() async {
        let service = PlayerService()
        await service.playQueue(
            [self.song("v1"), self.song("v2"), self.song("v3")],
            startingAt: 0
        )
        // It has been playing for a while, as a song dragged to its end has.
        service.currentRowStartedAt = ContinuousClock.now - .seconds(150)

        // The song is dragged to its end, so it finishes and Kaset starts the next row.
        await service.handleTrackEnded(observedVideoId: "v1", progress: 180, duration: 180)
        #expect(service.currentIndex == 1)
        #expect(service.currentTrack?.videoId == "v2")

        // YouTube Music completes its own advance after reporting the end, so the page now names the
        // row after the one Kaset just started — while that row has been playing for a moment.
        service.updateTrackMetadata(
            title: "Song v3",
            artist: "Someone",
            thumbnailUrl: "",
            videoId: "v3"
        )

        #expect(service.currentIndex == 1)
        #expect(service.currentTrack?.videoId == "v2")
    }

    @Test("An end reported for a track that started moments ago does not advance the queue")
    func endedRightAfterStartIsRejected() async {
        let service = PlayerService()
        await service.playQueue(
            [self.song("v1"), self.song("v2"), self.song("v3")],
            startingAt: 0
        )
        service.currentRowStartedAt = ContinuousClock.now - .seconds(150)
        await service.handleTrackEnded(observedVideoId: "v1", progress: 180, duration: 180)
        #expect(service.currentIndex == 1)

        // The page's leftover advance ends the row that just started and reports it as finished.
        await service.handleTrackEnded(observedVideoId: "v2", progress: 180, duration: 180)

        #expect(service.currentIndex == 1)
        #expect(service.currentTrack?.videoId == "v2")
    }

    @Test("Once the row has been playing for a while, a real advance is followed")
    func advanceAfterTheStartGraceIsFollowed() async {
        let service = PlayerService()
        await service.playQueue(
            [self.song("v1"), self.song("v2"), self.song("v3")],
            startingAt: 0
        )
        service.currentRowStartedAt = ContinuousClock.now - .seconds(30)
        // The page's start was already confirmed, so nothing is in flight to correct.
        service.isKasetInitiatedPlayback = false

        // The page moved on by itself, as it does when its own end-of-track advance runs.
        service.updateTrackMetadata(
            title: "Song v2",
            artist: "Someone",
            thumbnailUrl: "",
            videoId: "v2"
        )

        #expect(service.currentIndex == 1)
        #expect(service.currentTrack?.videoId == "v2")
    }

    @Test("Two signals for the same end advance the queue once")
    func overlappingAutomaticAdvancesAdvanceOnce() async {
        let service = PlayerService()
        await service.playQueue(
            [self.song("v1"), self.song("v2"), self.song("v3")],
            startingAt: 0
        )
        service.currentRowStartedAt = ContinuousClock.now - .seconds(150)

        // The page's `ended` event is already advancing the queue when the near-end metadata
        // observation reports the same transition. `next()` moves the index before it awaits, so a
        // second call would land on the row after the one that had just started.
        service.isAutomaticQueueAdvanceInFlight = true
        await service.advanceQueueForObservedTrackEnd()

        #expect(service.currentIndex == 0)
        #expect(service.currentTrack?.videoId == "v1")
    }

    @Test("An end report from media that never reached its end is ignored")
    func endedBeforeTheEndIsIgnored() async {
        let service = PlayerService()
        await service.playQueue([self.song("v1"), self.song("v2")], startingAt: 0)

        // A load that kept the old position ends immediately; that is not this track finishing.
        await service.handleTrackEnded(observedVideoId: "v1", progress: 2, duration: 180)

        #expect(service.currentIndex == 0)
        #expect(service.currentTrack?.videoId == "v1")
    }

    @Test("An end report from the end of the media advances the queue")
    func endedAtTheEndAdvances() async {
        let service = PlayerService()
        await service.playQueue([self.song("v1"), self.song("v2")], startingAt: 0)
        service.currentRowStartedAt = ContinuousClock.now - .seconds(150)

        await service.handleTrackEnded(observedVideoId: "v1", progress: 180, duration: 180)

        #expect(service.currentIndex == 1)
        #expect(service.currentTrack?.videoId == "v2")
    }

    @Test("The player's own words are believed while the bar still names the previous track")
    func playerApiTextOutranksALaggingBar() async {
        let service = PlayerService()
        let cardRow = Song(
            id: "v1",
            title: "Song",
            artists: [Artist(id: "card", name: "Song, Artist")],
            album: nil,
            duration: 200,
            thumbnailURL: nil,
            videoId: "v1"
        )
        await service.playQueue([cardRow, self.song("v2")], startingAt: 0)
        // Until the page says anything, the lyrics loader's gate is closed: nothing would search with
        // the card's words.
        #expect(service.hasObservedWebMetadata(for: "v1") == false)

        // The player reports the new track; the bar's link still points at the outgoing one. The
        // player API's own words are anchored to the video it holds, so they are taken at once.
        service.updateTrackMetadata(
            title: "Real Title",
            artist: "Real Artist",
            thumbnailUrl: "",
            videoId: "v1",
            playerBarVideoId: "outgoing",
            metadataFromPlayer: true
        )

        #expect(service.currentTrack?.title == "Real Title")
        #expect(service.currentTrack?.artistsDisplay == "Real Artist")
        // What the lyrics search waits for, and what it searches with: not the card's words.
        #expect(service.hasObservedWebMetadata(for: "v1"))
        #expect(service.observedWebMetadata?.artist == "Real Artist")
        #expect(service.lyricsSearchMetadata(for: "v1")?.artist == "Real Artist")
    }

    @Test("A row built from a card takes the page's title and byline")
    func cardRowTakesThePagesText() async {
        let service = PlayerService()
        let cardRow = Song(
            id: "v1",
            title: "Song",
            artists: [Artist(id: "card", name: "Song, Artist")],
            album: nil,
            duration: 200,
            thumbnailURL: nil,
            videoId: "v1"
        )
        await service.playQueue([cardRow, self.song("v2")], startingAt: 0)

        // The bar's link names the playing video, which anchors its words to this start.
        service.updateTrackMetadata(
            title: "Real Title",
            artist: "Real Artist",
            thumbnailUrl: "",
            videoId: "v1",
            playerBarVideoId: "v1"
        )

        #expect(service.currentTrack?.title == "Real Title")
        #expect(service.currentTrack?.artistsDisplay == "Real Artist")
        // The row stays the richer entry: its duration, artwork and like state are unchanged.
        #expect(service.currentTrack?.duration == 200)
    }

    @Test("Half a player bar does not rewrite the row a start came from")
    func incompleteObservationKeepsTheRowsText() async {
        let service = PlayerService()
        let cardRow = Song(
            id: "v1",
            title: "Real Title",
            artists: [Artist(id: "card", name: "Real Artist")],
            album: nil,
            duration: 200,
            thumbnailURL: nil,
            videoId: "v1"
        )
        await service.playQueue([cardRow], startingAt: 0)

        service.updateTrackMetadata(title: "Real Title", artist: "", thumbnailUrl: "", videoId: "v1")

        #expect(service.currentTrack?.title == "Real Title")
        #expect(service.currentTrack?.artistsDisplay == "Real Artist")
    }

    @Test("A page that advanced while its bar still shows the old track still moves the queue")
    func advanceWithALaggingBarRealignsTheQueue() async {
        let service = PlayerService()
        await service.playQueue(
            [self.song("v1"), self.song("v2"), self.song("v3")],
            startingAt: 0
        )
        service.currentRowStartedAt = ContinuousClock.now - .seconds(60)
        service.isKasetInitiatedPlayback = false

        // The player holds v2 while the bar is still rendering v1's title.
        service.updateTrackMetadata(
            title: "Song v1",
            artist: "Someone",
            thumbnailUrl: "",
            videoId: "v2",
            playerBarVideoId: "v1"
        )

        #expect(service.currentIndex == 1)
        #expect(service.currentTrack?.videoId == "v2")
        #expect(service.currentTrack?.title == "Song v2")
    }

    @Test("A report of the track playback just left does not move the queue back")
    func staleReportOfTheLeftTrackIsIgnored() async {
        let service = PlayerService()
        await service.playQueue(
            [self.song("v1"), self.song("v2"), self.song("v3")],
            startingAt: 0
        )
        // Kaset skips forward; the page confirms the new row a beat later.
        await service.next()
        service.isKasetInitiatedPlayback = false
        #expect(service.currentIndex == 1)

        // A poll that raced the swap still describes the track that was left behind, while the bar
        // already names the new one. Believing it realigned the queue to the previous row and flashed
        // its title in the now-playing surfaces until the next report corrected it.
        service.updateTrackMetadata(
            title: "Song v1",
            artist: "Someone",
            thumbnailUrl: "",
            videoId: "v1",
            playerBarVideoId: "v2"
        )

        #expect(service.currentIndex == 1)
        #expect(service.currentTrack?.videoId == "v2")
        #expect(service.currentTrack?.title == "Song v2")
        // The stale report does not seed the lyrics gate either: the search still waits for the new
        // track's own observation, never for the outgoing song's words.
        #expect(service.observedWebMetadata == nil)
        #expect(service.hasObservedWebMetadata(for: "v2") == false)
    }

    /// A queue row that already carries a title *and* a byline, so the page has something to contradict.
    private func row(_ videoId: String) -> Song {
        Song(
            id: videoId,
            title: "Song \(videoId)",
            artists: [Artist(id: "artist-\(videoId)", name: "Artist \(videoId)")],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: videoId
        )
    }

    @Test("Words with nothing tying them to the just-started track do not rename the row")
    func unanchoredTextRightAfterAStartIsIgnored() async {
        let service = PlayerService()
        await service.playQueue([self.row("v1"), self.row("v2"), self.row("v3")], startingAt: 0)
        await service.next()
        #expect(service.currentTrack?.title == "Song v2")

        // Measured on the real page: 0.2 s after a natural advance it reported the correct new video
        // id with another song's title, from the bar's DOM, with no bar link and nothing from the
        // player API. That is the page still painting its previous state, so it is not believed.
        service.updateTrackMetadata(
            title: "Hello (triple j Like A Version)",
            artist: "daine",
            thumbnailUrl: "",
            videoId: "v2",
            playerBarVideoId: "",
            metadataFromPlayer: false
        )

        #expect(service.currentTrack?.title == "Song v2")
        #expect(service.currentTrack?.artistsDisplay == "Artist v2")
        #expect(service.observedWebMetadata == nil)
    }

    @Test("The player API's words are anchored to the track it holds")
    func playerApiTextIsAdoptedRightAfterAStart() async {
        let service = PlayerService()
        await service.playQueue([self.row("v1"), self.row("v2")], startingAt: 0)
        await service.next()

        service.updateTrackMetadata(
            title: "Real Title",
            artist: "Real Artist",
            thumbnailUrl: "",
            videoId: "v2",
            playerBarVideoId: "",
            metadataFromPlayer: true
        )

        #expect(service.currentTrack?.title == "Real Title")
        #expect(service.currentTrack?.artistsDisplay == "Real Artist")
        #expect(service.hasObservedWebMetadata(for: "v2"))
        #expect(service.observedWebMetadata?.artist == "Real Artist")
    }

    @Test("A bar whose link names the playing video anchors its words")
    func barNamingThePlayingVideoIsAdoptedRightAfterAStart() async {
        let service = PlayerService()
        await service.playQueue([self.row("v1"), self.row("v2")], startingAt: 0)
        await service.next()

        service.updateTrackMetadata(
            title: "Real Title",
            artist: "Real Artist",
            thumbnailUrl: "",
            videoId: "v2",
            playerBarVideoId: "v2",
            metadataFromPlayer: false
        )

        #expect(service.currentTrack?.title == "Real Title")
        #expect(service.observedWebMetadata?.title == "Real Title")
    }

    @Test("Once the start is no longer recent, the page's words may correct the row")
    func unanchoredTextIsAdoptedAfterTheStartGrace() async {
        let service = PlayerService()
        await service.playQueue([self.row("v1"), self.row("v2")], startingAt: 0)
        await service.next()
        // The start is long past: whatever the page says now is not a leftover paint of the previous one.
        service.lastStartedTrack = (videoId: "v2", at: ContinuousClock.now - .seconds(10))

        service.updateTrackMetadata(
            title: "Refined Title",
            artist: "Refined Artist",
            thumbnailUrl: "",
            videoId: "v2",
            playerBarVideoId: "",
            metadataFromPlayer: false
        )

        #expect(service.currentTrack?.title == "Refined Title")
        #expect(service.observedWebMetadata?.title == "Refined Title")
    }

    @Test("The outgoing song's words do not replace the row even under the new video's id")
    func staleTextUnderTheNewVideoIdIsIgnored() async {
        let service = PlayerService()
        await service.playQueue(
            [self.song("v1"), self.song("v2"), self.song("v3")],
            startingAt: 0
        )
        await service.next()
        service.isKasetInitiatedPlayback = false
        #expect(service.currentTrack?.title == "Song v2")

        // Mid-swap the page can pair the new video's id with the outgoing song's words. There is no way
        // to tell that from a correction by id alone, and adopting it flashed the previous title in the
        // now-playing column until the next report.
        service.updateTrackMetadata(
            title: "Song v1",
            artist: "Someone",
            thumbnailUrl: "",
            videoId: "v2",
            playerBarVideoId: "v2",
            metadataFromPlayer: true
        )

        #expect(service.currentTrack?.videoId == "v2")
        #expect(service.currentTrack?.title == "Song v2")
        #expect(service.observedWebMetadata == nil)
    }

    @Test("The same report is believed once it is no longer a stale one")
    func reportAfterTheDepartedWindowIsBelieved() async {
        let service = PlayerService()
        await service.playQueue(
            [self.song("v1"), self.song("v2"), self.song("v3")],
            startingAt: 0
        )
        await service.next()
        service.isKasetInitiatedPlayback = false
        // The page moving back to the previous row is a real move once it is not the report of a
        // swap in flight; the guard is a window, not a ban on the track.
        service.departedTracks = [
            (videoId: "v1", titles: ["song v1"], at: ContinuousClock.now - .seconds(10)),
        ]

        service.updateTrackMetadata(
            title: "Song v1",
            artist: "Someone",
            thumbnailUrl: "",
            videoId: "v1"
        )

        #expect(service.currentIndex == 0)
        #expect(service.currentTrack?.videoId == "v1")
    }

    @Test("Starting a track again makes its own reports believable")
    func startingALeftTrackAgainClearsTheStaleWindow() async {
        let service = PlayerService()
        let songs = [self.song("v1"), self.song("v2")]
        await service.playQueue(songs, startingAt: 0)
        await service.next()

        // Previous, or picking the row again, makes v1 the playing track rather than the left one.
        await service.play(song: songs[0])
        service.updateTrackMetadata(
            title: "Song v1",
            artist: "Someone",
            thumbnailUrl: "",
            videoId: "v1"
        )

        #expect(service.observedWebMetadata?.videoId == "v1")
        #expect(service.observedWebMetadata?.title == "Song v1")
    }

    @Test("A player bar describing another track cannot rewrite the playing row")
    func playerBarFromAnotherTrackIsIgnored() async {
        let service = PlayerService()
        await service.playQueue(
            [self.song("v1"), self.song("v2"), self.song("v3")],
            startingAt: 0
        )
        service.currentTrack = self.song("v2")
        service.pendingPlayVideoId = "v2"
        service.currentIndex = 1

        service.updateTrackMetadata(
            title: "Song v1",
            artist: "Someone",
            thumbnailUrl: "",
            videoId: "v2",
            playerBarVideoId: "v1"
        )

        #expect(service.currentTrack?.title == "Song v2")
        #expect(service.observedWebMetadata == nil)
        #expect(service.currentIndex == 1)
    }

    @Test("A player bar describing the playing track still updates it")
    func playerBarForThePlayingTrackIsAccepted() async {
        let service = PlayerService()
        await service.playQueue(
            [self.song("v1"), self.song("v2")],
            startingAt: 0
        )
        service.currentTrack = self.song("v2")
        service.pendingPlayVideoId = "v2"
        service.currentIndex = 1

        service.updateTrackMetadata(
            title: "Song v2",
            artist: "Someone",
            thumbnailUrl: "",
            videoId: "v2",
            playerBarVideoId: "v2"
        )

        #expect(service.observedWebMetadata?.videoId == "v2")
        #expect(service.observedWebMetadata?.title == "Song v2")
    }

    @Test("An unknown player bar track is not a description of the playing one")
    func playerBarWithoutAnIdDoesNotBlockUpdates() async {
        let service = PlayerService()
        await service.playQueue([self.song("v1"), self.song("v2")], startingAt: 0)
        service.currentTrack = self.song("v2")
        service.pendingPlayVideoId = "v2"
        service.currentIndex = 1

        service.updateTrackMetadata(
            title: "Song v2",
            artist: "Someone",
            thumbnailUrl: "",
            videoId: "v2",
            playerBarVideoId: ""
        )

        #expect(service.observedWebMetadata?.videoId == "v2")
    }
}
