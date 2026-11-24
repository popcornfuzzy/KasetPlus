import Foundation
import SwiftUI
import Testing
@testable import Kaset

// MARK: - PodcastVideoPreferencesTests

@Suite(.tags(.service))
@MainActor
struct PodcastVideoPreferencesTests {
    @Test("the video can be switched off and on again")
    func videoEnabledToggle() {
        let preferences = PodcastVideoPreferences()
        #expect(preferences.isVideoEnabled)

        preferences.isVideoEnabled = false
        #expect(preferences.isVideoEnabled == false)

        preferences.isVideoEnabled = true
        #expect(preferences.isVideoEnabled)
    }

    @Test("an undeclared slot stays empty instead of resolving to a stale bounds")
    func slotAnchorStartsEmpty() {
        #expect(PodcastVideoSlotAnchor.defaultValue == nil)

        var value: Anchor<CGRect>?
        PodcastVideoSlotAnchor.reduce(value: &value) { nil }

        #expect(value == nil)
    }
}

// MARK: - FullscreenPodcastPresentationTests

@Suite(.serialized, .tags(.service))
@MainActor
struct FullscreenPodcastPresentationTests {
    init() {
        UserDefaults.standard.removeObject(forKey: PlayerService.playbackRateKey)
        UserDefaults.standard.removeObject(forKey: PlayerService.volumeKey)
    }

    @Test("the podcast experience is presented only for podcasts in fullscreen")
    func presentationRequiresPodcastInFullscreen() {
        let player = PlayerService()
        player.currentTrack = Self.song
        #expect(player.isFullscreenPodcastPresented == false)

        player.showFullscreenNowPlaying = true
        #expect(player.isFullscreenPodcastPresented)

        // A song keeps the music experience, even in fullscreen.
        player.currentTrack = TestFixtures.makeSong(id: "song-1", title: "A Song")
        #expect(player.isFullscreenPodcastPresented == false)

        player.showFullscreenNowPlaying = false
        #expect(player.isFullscreenPodcastPresented == false)
    }

    @Test("a video surface exists only when the episode or the player reports video")
    func videoSurfaceRequiresVideo() {
        let player = PlayerService()
        #expect(player.hasVideoSurface == false)

        player.currentTrackHasVideo = true
        #expect(player.hasVideoSurface)
    }

    @Test("playback rate is clamped and persisted")
    func playbackRateIsClampedAndPersisted() {
        let player = PlayerService()
        #expect(player.playbackRate == 1.0)

        player.setPlaybackRate(1.5)
        #expect(player.playbackRate == 1.5)
        #expect(UserDefaults.standard.double(forKey: PlayerService.playbackRateKey) == 1.5)

        player.setPlaybackRate(9)
        #expect(player.playbackRate == PlayerService.maximumPlaybackRate)

        player.setPlaybackRate(0.1)
        #expect(player.playbackRate == PlayerService.minimumPlaybackRate)
    }

    @Test("a saved playback rate is restored, out-of-range values are not")
    func playbackRateRestoration() {
        UserDefaults.standard.set(1.25, forKey: PlayerService.playbackRateKey)
        #expect(PlayerService().playbackRate == 1.25)

        UserDefaults.standard.set(4.0, forKey: PlayerService.playbackRateKey)
        #expect(PlayerService().playbackRate == 1.0)
    }

    private static let song = Song(
        id: "episode-1",
        title: "Episode One",
        artists: [Artist(id: "podcast", name: "Some Show")],
        videoId: "episode-1"
    )
}

// MARK: - FullscreenPodcastGeometryTests

/// The fullscreen podcast experience has to divide whatever window it is given. These pin the
/// arithmetic at the window it is most often opened in — the 2558×1401 usable area of a 5K display —
/// and at the sizes around it, so the columns cannot drift back into a capped strip in the middle of
/// a large window, nor push the transport row off a short one.
@Suite(.tags(.model))
struct FullscreenPodcastGeometryTests {
    /// The app's recommended window, and the one the report is about.
    private static let recommended = FullscreenPodcastGeometry(
        windowSize: CGSize(width: 2558, height: 1401),
        showsTranscript: true
    )

    @Test("The recommended window is filled instead of holding a capped strip")
    func recommendedWindowIsFilled() {
        // Before this arithmetic the content stopped at 1320pt, leaving ~619pt of empty window on
        // either side, with a 478pt-wide video in the middle of it.
        #expect(abs(Self.recommended.contentWidth - Self.recommended.availableWidth) < 0.01)
        #expect(Self.recommended.contentWidth > 1320)
        #expect(Self.recommended.videoWidth > 1320)
        #expect(Self.recommended.horizontalPadding <= 72)
    }

    @Test("The video is a little over half the width and the transcript a little under it")
    func columnsShareTheRecommendedWindow() {
        let videoShare = Self.recommended.videoWidth / Self.recommended.contentWidth
        #expect(abs(videoShare - FullscreenPodcastGeometry.maximumVideoWidthRatio) < 0.02)
        #expect(Self.recommended.transcriptWidth >= 900)
        #expect(Self.recommended.transcriptWidth <= FullscreenPodcastGeometry.maximumTranscriptWidth)
    }

    @Test("The video keeps the episode's 16:9 shape at every size")
    func videoKeepsItsShape() {
        let sizes = [
            CGSize(width: 2558, height: 1401),
            CGSize(width: 1490, height: 900),
            CGSize(width: 900, height: 600),
        ]
        for size in sizes {
            let geometry = FullscreenPodcastGeometry(windowSize: size, showsTranscript: true)
            let expected = geometry.videoWidth / FullscreenPodcastGeometry.videoAspectRatio
            #expect(abs(geometry.videoHeight - expected) < 0.01, "at \(Int(size.width))×\(Int(size.height))")
        }
    }

    @Test("The media column fits the stage at every window that can open the experience")
    func mediaColumnFitsTheStage() {
        for height in stride(from: 600.0, through: 1600.0, by: 100.0) {
            for width in [900.0, 1490.0, 2558.0] {
                let geometry = FullscreenPodcastGeometry(
                    windowSize: CGSize(width: width, height: height),
                    showsTranscript: true
                )
                #expect(
                    geometry.videoHeight + FullscreenPodcastGeometry.mediaChromeHeight <= geometry.stageHeight + 1,
                    "at \(Int(width))×\(Int(height)): \(geometry.videoHeight) + 256 in \(geometry.stageHeight)"
                )
            }
        }
    }

    @Test("A window wide enough to spare does not stretch the transcript past its measure")
    func transcriptKeepsItsMeasure() {
        let wide = FullscreenPodcastGeometry(windowSize: CGSize(width: 2558, height: 700), showsTranscript: true)
        #expect(wide.transcriptWidth == FullscreenPodcastGeometry.maximumTranscriptWidth)
        // Centred, so the columns do not lean against one side of the window.
        #expect(wide.contentWidth < wide.availableWidth)
    }

    @Test("Hiding the transcript gives its column to the video")
    func hidingTheTranscriptWidensTheVideo() {
        let hidden = FullscreenPodcastGeometry(windowSize: CGSize(width: 2558, height: 1401), showsTranscript: false)
        #expect(hidden.transcriptWidth == 0)
        #expect(abs(hidden.contentWidth - hidden.videoWidth) < 0.01)
        #expect(hidden.videoWidth > Self.recommended.videoWidth)
        #expect(hidden.videoHeight + FullscreenPodcastGeometry.mediaChromeHeight <= hidden.stageHeight + 1)
    }

    @Test("A window too small to lay out still answers with numbers a frame can take")
    func degenerateWindowStaysSane() {
        for size in [CGSize(width: 0, height: 0), CGSize(width: 900, height: 0)] {
            let geometry = FullscreenPodcastGeometry(windowSize: size, showsTranscript: true)
            #expect(geometry.videoWidth >= 0)
            #expect(geometry.transcriptWidth >= 0)
            #expect(geometry.contentWidth.isFinite)
        }
    }
}
