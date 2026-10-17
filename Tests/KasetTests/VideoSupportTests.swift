import Foundation
import Testing
@testable import Kaset

/// Tests for fullscreen now-playing and related capability state.
@Suite(.serialized, .tags(.service))
@MainActor
struct VideoSupportTests {
    var playerService: PlayerService

    init() {
        UserDefaults.standard.removeObject(forKey: "playerVolume")
        UserDefaults.standard.removeObject(forKey: "playerVolumeBeforeMute")
        self.playerService = PlayerService()
    }

    @Test("currentTrackHasVideo initially false")
    func currentTrackHasVideoInitiallyFalse() {
        #expect(self.playerService.currentTrackHasVideo == false)
    }

    @Test("showFullscreenNowPlaying initially false")
    func showFullscreenNowPlayingInitiallyFalse() {
        #expect(self.playerService.showFullscreenNowPlaying == false)
    }

    @Test("updateVideoAvailability sets hasVideo correctly")
    func updateVideoAvailabilitySetsHasVideo() {
        self.playerService.updateVideoAvailability(hasVideo: true)
        #expect(self.playerService.currentTrackHasVideo == true)

        self.playerService.updateVideoAvailability(hasVideo: false)
        #expect(self.playerService.currentTrackHasVideo == false)
    }

    @Test("fullscreen now playing can be enabled even when hasVideo is false")
    func fullscreenCanBeEnabledWhenNoVideo() {
        #expect(self.playerService.currentTrackHasVideo == false)
        self.playerService.showFullscreenNowPlaying = true
        #expect(self.playerService.showFullscreenNowPlaying == true)
    }

    @Test("fullscreen now playing stays enabled when hasVideo changes")
    func fullscreenStaysEnabledWhenHasVideoChanges() {
        self.playerService.showFullscreenNowPlaying = true
        self.playerService.updateVideoAvailability(hasVideo: false)
        #expect(self.playerService.showFullscreenNowPlaying == true)
    }

    @Test("enabling fullscreen closes lyrics and queue")
    func enablingFullscreenClosesPanels() {
        self.playerService.showLyrics = true
        self.playerService.showQueue = true
        self.playerService.showFullscreenNowPlaying = true

        #expect(self.playerService.showFullscreenNowPlaying == true)
        #expect(self.playerService.showLyrics == false)
        #expect(self.playerService.showQueue == false)
    }

    @Test("enabling lyrics closes fullscreen")
    func enablingLyricsClosesFullscreen() {
        self.playerService.showFullscreenNowPlaying = true
        self.playerService.showLyrics = true

        #expect(self.playerService.showLyrics == true)
        #expect(self.playerService.showFullscreenNowPlaying == false)
    }

    @Test("enabling queue closes fullscreen")
    func enablingQueueClosesFullscreen() {
        self.playerService.showFullscreenNowPlaying = true
        self.playerService.showQueue = true

        #expect(self.playerService.showQueue == true)
        #expect(self.playerService.showFullscreenNowPlaying == false)
    }

    @Test("Song.hasVideo property exists and defaults to nil")
    func songHasVideoPropertyExists() {
        let song = Song(
            id: "test",
            title: "Test Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "test-video"
        )
        #expect(song.hasVideo == nil)
    }

    @Test("API no-video verdict hides the surface despite DOM and dimensions")
    func apiNoVideoVerdictHidesSurface() async {
        // The reported bug: an ATV track (static still frame, no counterpart) showed
        // the video button because the still frame decodes at real dimensions.
        let song = Song(
            id: "atv-1",
            title: "ATV Song",
            artists: [Artist(id: "artist-1", name: "Artist")],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "atv-1"
        )
        await self.playerService.play(song: song)

        // DOM fast path fires first, then the still frame reports dimensions.
        self.playerService.updateVideoAvailability(hasVideo: true)
        self.playerService.updateMiniPlayerVideoDimensions(width: 1280, height: 720)
        #expect(self.playerService.hasVideoSurface == true)

        // The API verdict lands (ATV, no counterpart): the button must go away …
        self.playerService.updateVideoAvailabilityFromAPI(hasVideo: false, videoId: "atv-1")
        #expect(self.playerService.hasVideoSurface == false)

        // … and later DOM updates must not resurrect it.
        self.playerService.updateVideoAvailability(hasVideo: true)
        #expect(self.playerService.currentTrackHasVideo == false)
        #expect(self.playerService.hasVideoSurface == false)
    }

    @Test("API has-video verdict keeps the surface")
    func apiHasVideoVerdictKeepsSurface() async {
        let song = Song(
            id: "omv-1",
            title: "OMV Song",
            artists: [Artist(id: "artist-1", name: "Artist")],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "omv-1"
        )
        await self.playerService.play(song: song)

        self.playerService.updateVideoAvailabilityFromAPI(hasVideo: true, videoId: "omv-1")
        #expect(self.playerService.hasVideoSurface == true)

        // A later DOM "no video" must not hide a confirmed video either.
        self.playerService.updateVideoAvailability(hasVideo: false)
        #expect(self.playerService.hasVideoSurface == true)
    }

    @Test("track change resets the API verdict so the DOM fast path lives again")
    func trackChangeResetsApiVerdict() async {
        let first = Song(
            id: "atv-1",
            title: "ATV Song",
            artists: [Artist(id: "artist-1", name: "Artist")],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "atv-1"
        )
        await self.playerService.play(song: first)
        self.playerService.updateVideoAvailabilityFromAPI(hasVideo: false, videoId: "atv-1")
        #expect(self.playerService.hasVideoSurface == false)

        let second = Song(
            id: "song-2",
            title: "Next Song",
            artists: [Artist(id: "artist-2", name: "Artist 2")],
            album: nil,
            duration: 200,
            thumbnailURL: nil,
            videoId: "song-2"
        )
        await self.playerService.play(song: second)

        // No verdict for the new track yet: DOM updates apply again.
        self.playerService.updateVideoAvailability(hasVideo: true)
        #expect(self.playerService.currentTrackHasVideo == true)
        #expect(self.playerService.hasVideoSurface == true)
    }

    @Test("podcasts keep dimension-based surface despite a negative API verdict")
    func podcastsKeepDimensionBasedSurface() async {
        // Episode video-ness is only observable from the player itself, so the
        // legacy dimensions signal stays valid for podcasts.
        let episode = Song(
            id: "ep-1",
            title: "Episode 1",
            artists: [Artist(id: "podcast", name: "Test Show")],
            album: nil,
            duration: 1200,
            thumbnailURL: nil,
            videoId: "ep-1"
        )
        await self.playerService.play(song: episode)
        self.playerService.updateVideoAvailabilityFromAPI(hasVideo: false, videoId: "ep-1")
        self.playerService.updateMiniPlayerVideoDimensions(width: 1280, height: 720)
        #expect(self.playerService.hasVideoSurface == true)
    }

    @Test("Song.hasVideo can be set explicitly")
    func songHasVideoCanBeSet() {
        let songWithVideo = Song(
            id: "test",
            title: "Test Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "test-video",
            hasVideo: true
        )
        #expect(songWithVideo.hasVideo == true)

        let songWithoutVideo = Song(
            id: "test2",
            title: "Test Song 2",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "test-video-2",
            hasVideo: false
        )
        #expect(songWithoutVideo.hasVideo == false)
    }
}
