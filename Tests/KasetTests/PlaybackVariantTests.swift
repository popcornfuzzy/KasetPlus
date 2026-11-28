import Foundation
import Testing
@testable import Kaset

/// Playback chooses the song version normally, and the sidebar video switches the stream.
///
/// The queue entry, its artwork and its metadata stay the song in both directions: only the page
/// that is played changes. Page loads are observed through a recording hook, so these cases need
/// no live page.
@Suite(.serialized, .tags(.service))
@MainActor
struct PlaybackVariantTests {
    private var playerService: PlayerService
    private var mockClient: MockYTMusicClient

    init() {
        UserDefaults.standard.removeObject(forKey: "kaset.saved.queue")
        UserDefaults.standard.removeObject(forKey: "kaset.saved.queueIndex")
        UserDefaults.standard.removeObject(forKey: "kaset.saved.playbackSession")
        SingletonPlayerWebView.shared.currentVideoId = nil

        self.mockClient = MockYTMusicClient()
        self.playerService = PlayerService()
        self.playerService.setYTMusicClient(self.mockClient)
    }

    // MARK: - Fixtures

    private func makeVideo() -> Song {
        Song(
            id: "video-id",
            title: "Song",
            artists: [Artist(id: "UC1", name: "Artist")],
            duration: 200,
            videoId: "video-id",
            musicVideoType: .omv
        )
    }

    private func makeAudio(video: Song? = nil) -> Song {
        let audio = Song(
            id: "audio-id",
            title: "Song",
            artists: [Artist(id: "UC1", name: "Artist")],
            duration: 200,
            videoId: "audio-id",
            musicVideoType: .atv
        )
        guard let video else { return audio }
        return audio.paired(with: video)
    }

    // MARK: - Tests

    @Test("Normal playback plays the song version, not the video")
    func normalPlaybackPlaysSong() async {
        let video = self.makeVideo()
        let audio = self.makeAudio(video: video)

        await self.playerService.play(song: audio)

        #expect(self.playerService.currentTrack?.videoId == "audio-id")
        #expect(self.playerService.pendingPlayVideoId == "audio-id")
        #expect(self.playerService.isSidebarVideoShowing == false)
    }

    @Test("The sidebar video plays the video version from the position that was playing")
    func videoTogglePlaysVideoVariant() async {
        let video = self.makeVideo()
        let audio = self.makeAudio(video: video)

        await self.playerService.play(song: audio)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 42, duration: 200)
        self.playerService.setSidebarVideoEnabled(true)

        #expect(self.playerService.isSidebarVideoShowing == true)
        #expect(self.playerService.pendingPlayVideoId == "video-id")
        // The queue row and the now-playing metadata are still the song.
        #expect(self.playerService.currentTrack?.videoId == "audio-id")
        #expect(self.playerService.pendingPlaybackVariantSeek?.videoId == "video-id")
        #expect(self.playerService.pendingPlaybackVariantSeek?.position == 42)
        #expect(self.playerService.pendingPlaybackVariantSeek?.resumesPlayback == true)
    }

    @Test("Showing the artwork again plays the song version")
    func artworkTogglePlaysSongAgain() async {
        let video = self.makeVideo()
        let audio = self.makeAudio(video: video)

        await self.playerService.play(song: audio)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 75, duration: 200)
        self.playerService.setSidebarVideoEnabled(true)
        self.playerService.updatePlaybackState(isPlaying: true, progress: 80, duration: 200)
        self.playerService.setSidebarVideoEnabled(false)

        #expect(self.playerService.isSidebarVideoShowing == false)
        #expect(self.playerService.pendingPlayVideoId == "audio-id")
        #expect(self.playerService.currentTrack?.videoId == "audio-id")
        #expect(self.playerService.pendingPlaybackVariantSeek?.videoId == "audio-id")
        #expect(self.playerService.pendingPlaybackVariantSeek?.position == 80)
    }

    @Test("A paused track stays paused across the switch")
    func pausedTrackStaysPaused() async {
        let video = self.makeVideo()
        let audio = self.makeAudio(video: video)

        await self.playerService.play(song: audio)
        // The page reports itself playing before a pause is a pause; a ready-to-play state is not one.
        self.playerService.updatePlaybackState(isPlaying: true, progress: 30, duration: 200)
        self.playerService.updatePlaybackState(isPlaying: false, progress: 30, duration: 200)
        self.playerService.setSidebarVideoEnabled(true)

        #expect(self.playerService.state == .paused)
        #expect(self.playerService.pendingPlaybackVariantSeek?.resumesPlayback == false)
    }

    @Test("With video showing, the next track starts on its video page")
    func stickyVideoStartsOnVideoPage() async {
        let video = self.makeVideo()
        let audio = self.makeAudio(video: video)
        self.playerService.isSidebarVideoEnabled = true

        await self.playerService.play(song: audio)

        #expect(self.playerService.pendingPlayVideoId == "video-id")
        #expect(self.playerService.currentTrack?.videoId == "audio-id")
        #expect(self.playerService.isSidebarVideoShowing == true)
    }

    @Test("A video is resolved to its song before its page is chosen")
    func videoResolvesBeforePlayback() async {
        let video = self.makeVideo()
        let audio = self.makeAudio()
        self.mockClient.songResponses["audio-id"] = audio
        self.mockClient.searchResponse = SearchResponse(songs: [audio], albums: [], artists: [], playlists: [])

        await self.playerService.playQueue([video], startingAt: 0)

        #expect(self.mockClient.searchQueries == ["Song Artist"])
        #expect(self.playerService.queue.map(\.videoId) == ["audio-id"])
        #expect(self.playerService.currentTrack?.videoId == "audio-id")
        #expect(self.playerService.currentTrackVideoVariant?.videoId == "video-id")
        #expect(self.playerService.pendingPlayVideoId == "audio-id")
        // The single page that was loaded is the song's: resolving did not reload a playing video.
        #expect(self.playerService.pendingPlaybackVariantSeek == nil)
    }

    @Test("A correction for the previous track does not replay over a newer click")
    func staleCorrectionDoesNotOverrideNewerClick() async {
        let first = self.makeVideo()
        let second = self.makeAudio()
        await self.playerService.playQueue([first], startingAt: 0)
        #expect(self.playerService.currentTrack?.videoId == "video-id")

        // The page reports another track while the start is unconfirmed; the handler decides to
        // replay the row and schedules that for the next turn.
        self.playerService.updateTrackMetadata(
            title: "Another Song",
            artist: "Another Artist",
            thumbnailUrl: "",
            videoId: "another-id"
        )

        // The reader clicks a new song before that correction runs.
        await self.playerService.play(song: second)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(self.playerService.currentTrack?.videoId == "audio-id")
        #expect(self.playerService.pendingPlayVideoId == "audio-id")
    }

    @Test("A mix still loading does not replace a song started after it")
    func staleMixDoesNotStartPlayback() async {
        let audio = self.makeAudio()
        self.mockClient.songResponses["audio-id"] = audio
        self.mockClient.mixQueueResult = RadioQueueResult(songs: [self.makeVideo()], continuationToken: nil)
        self.mockClient.mixQueueDelay = .milliseconds(120)

        let mixTask = Task { await self.playerService.playWithMix(playlistId: "MIX", startVideoId: nil) }
        try? await Task.sleep(for: .milliseconds(20))
        await self.playerService.play(song: audio)
        #expect(self.playerService.currentTrack?.videoId == "audio-id")

        await mixTask.value
        try? await Task.sleep(for: .milliseconds(20))

        #expect(self.playerService.currentTrack?.videoId == "audio-id")
        #expect(self.playerService.pendingPlayVideoId == "audio-id")
    }

    @Test("A playlist row of either variant reports as the playing track")
    func bothVariantsReportAsPlaying() async {
        let video = self.makeVideo()
        let audio = self.makeAudio(video: video)

        await self.playerService.play(song: audio)

        // A generated playlist lists the video; the queue and the player carry the song.
        #expect(self.playerService.isPlaybackTrack(videoId: "audio-id"))
        #expect(self.playerService.isPlaybackTrack(videoId: "video-id"))
        #expect(self.playerService.isPlaybackTrack(videoId: "other-id") == false)
    }

    @Test("Another queued track's variant is not reported as playing")
    func anotherTracksVariantIsNotPlaying() async {
        let video = self.makeVideo()
        let audio = self.makeAudio(video: video)
        let otherVideo = Song(
            id: "other-video",
            title: "Other",
            artists: [Artist(id: "UC2", name: "Other Artist")],
            duration: 180,
            videoId: "other-video",
            musicVideoType: .omv
        )
        self.mockClient.songResponses["other-video"] = otherVideo
        self.mockClient.searchResponse = SearchResponse(
            songs: [audio], albums: [], artists: [], playlists: []
        )

        await self.playerService.playQueue([audio, otherVideo], startingAt: 0)

        #expect(self.playerService.isPlaybackTrack(videoId: "audio-id"))
        #expect(self.playerService.isPlaybackTrack(videoId: "other-video") == false)
    }

    @Test("A link that carries only a video id plays that video's song version")
    func linkedVideoPlaysItsSong() async {
        let video = self.makeVideo()
        let audio = self.makeAudio(video: video)
        self.mockClient.songResponses["video-id"] = video
        self.mockClient.searchResponse = SearchResponse(songs: [audio], albums: [], artists: [], playlists: [])

        // `AppDelegate` hands a URL over exactly like this: only the id is known.
        let link = Song(id: "video-id", title: "Loading...", artists: [], videoId: "video-id")
        await self.playerService.play(song: link)

        #expect(self.mockClient.getSongVideoIds.first == "video-id")
        #expect(self.mockClient.searchQueries == ["Song Artist"])
        #expect(self.playerService.currentTrack?.videoId == "audio-id")
        #expect(self.playerService.currentTrack?.title == "Song")
        #expect(self.playerService.currentTrackVideoVariant?.videoId == "video-id")
        #expect(self.playerService.pendingPlayVideoId == "audio-id")
    }

    @Test("A link to an audio track plays it without a song search")
    func linkedAudioPlaysDirectly() async {
        let audio = self.makeAudio()
        self.mockClient.songResponses["audio-id"] = audio

        let link = Song(id: "audio-id", title: "Loading...", artists: [], videoId: "audio-id")
        await self.playerService.play(song: link)

        #expect(self.playerService.currentTrack?.videoId == "audio-id")
        #expect(self.playerService.currentTrack?.title == "Song")
        #expect(self.mockClient.searchQueries.isEmpty)
    }

    @Test("Clicking a video row keeps its place in the queue")
    func videoRowKeepsItsQueuePlace() async {
        let audio = self.makeAudio()
        let video = self.makeVideo().paired(with: audio)
        let first = Song(
            id: "first-id",
            title: "First",
            artists: [Artist(id: "UC2", name: "Artist")],
            duration: 180,
            videoId: "first-id"
        )
        let last = Song(
            id: "last-id",
            title: "Last",
            artists: [Artist(id: "UC2", name: "Artist")],
            duration: 180,
            videoId: "last-id"
        )
        self.mockClient.songResponses["audio-id"] = audio
        self.mockClient.songResponses["last-id"] = last

        await self.playerService.playQueue([first, video, last], startingAt: 1)

        #expect(self.playerService.queue.map(\.videoId) == ["first-id", "audio-id", "last-id"])
        #expect(self.playerService.currentIndex == 1)
        #expect(self.playerService.currentTrack?.videoId == "audio-id")

        // Next must walk on from the row that was clicked, not restart at the queue's first row.
        await self.playerService.next()
        #expect(self.playerService.currentIndex == 2)
        #expect(self.playerService.currentTrack?.videoId == "last-id")
    }

    @Test("The previous video's late report does not move the queue to the new track")
    func previousVideoReportIsIgnored() async {
        let firstAudio = Song(
            id: "audio-a",
            title: "First Song",
            artists: [Artist(id: "UC1", name: "Artist")],
            duration: 200,
            videoId: "audio-a",
            musicVideoType: .atv
        )
        let firstVideo = Song(
            id: "video-a",
            title: "First Song",
            artists: [Artist(id: "UC1", name: "Artist")],
            duration: 200,
            videoId: "video-a",
            musicVideoType: .omv
        )
        let secondAudio = Song(
            id: "audio-b",
            title: "Second Song",
            artists: [Artist(id: "UC1", name: "Artist")],
            duration: 200,
            videoId: "audio-b",
            musicVideoType: .atv
        )
        let secondVideo = Song(
            id: "video-b",
            title: "Second Song",
            artists: [Artist(id: "UC1", name: "Artist")],
            duration: 200,
            videoId: "video-b",
            musicVideoType: .omv
        )
        self.mockClient.songResponses["audio-a"] = firstAudio.paired(with: firstVideo)
        self.mockClient.songResponses["audio-b"] = secondAudio.paired(with: secondVideo)
        self.playerService.isSidebarVideoEnabled = true

        await self.playerService.playQueue(
            [firstAudio.paired(with: firstVideo), secondAudio.paired(with: secondVideo)],
            startingAt: 0
        )
        await self.playerService.next()
        #expect(self.playerService.pendingPlayVideoId == "video-b")

        // The page that was showing the first video reports once more after the switch.
        self.playerService.updateTrackMetadata(
            title: "First Song",
            artist: "Artist",
            thumbnailUrl: "",
            videoId: "video-a"
        )

        #expect(self.playerService.currentTrack?.videoId == "audio-b")
        #expect(self.playerService.pendingPlayVideoId == "video-b")
        #expect(self.playerService.currentIndex == 1)
    }

    @Test("The settle check accepts the video page of the song that is playing")
    func settleAcceptsPairedVideoPage() async {
        let video = self.makeVideo()
        let audio = self.makeAudio(video: video)
        self.playerService.isSidebarVideoEnabled = true

        await self.playerService.play(song: audio)
        #expect(self.playerService.pendingPlayVideoId == "video-id")

        // What `loadVideo` asks after starting the video page in place.
        self.playerService.pageSettleVideoId = "video-id"
        self.playerService.pageSettleReassertionsLeft = 1
        self.playerService.settlePagePlayback(expectedVideoId: "video-id", observedVideoId: "video-id")

        // Confirmed, not corrected: the in-place try is still there, because the page holds the
        // same track under its other id.
        #expect(self.playerService.pageSettleVideoId == nil)
        #expect(self.playerService.pageSettleReassertionsLeft == 1)
    }

    @Test("A pause during a load is kept and applied when the page can take it")
    func pauseDuringLoadIsKept() async {
        let video = self.makeVideo()
        let audio = self.makeAudio(video: video)

        await self.playerService.play(song: audio)
        #expect(self.playerService.state == .loading)

        await self.playerService.pause()
        #expect(self.playerService.state == .paused)
        #expect(self.playerService.pauseWhenPageReady == true)

        await self.playerService.resume()
        #expect(self.playerService.pauseWhenPageReady == false)
    }

    @Test("The transport follows playback state, not the presence of a page")
    func playPauseFollowsPlaybackState() async {
        let video = self.makeVideo()
        let audio = self.makeAudio(video: video)

        await self.playerService.play(song: audio)
        // No WebView exists in a unit test, so `shouldLoadPendingVideoBeforePlayback` would send this
        // press down the "load it first" path. The transport question is about state, so drop the
        // pending page id that no page in the test carries.
        self.playerService.pendingPlayVideoId = nil
        self.playerService.updatePlaybackState(isPlaying: true, progress: 12, duration: 200)
        #expect(self.playerService.state == .playing)

        await self.playerService.playPause()
        #expect(self.playerService.state == .paused)
    }
}
