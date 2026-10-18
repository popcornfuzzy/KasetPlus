import Foundation
import Testing
@testable import Kaset

/// The contract for a showing sidebar video, which a full page load destroys.
///
/// Leaving podcast fullscreen (or switching the sidebar to video) puts the page on an id
/// Kaset may not track while the title still names the item that is playing. That
/// observation must fold back onto the item; anything else — another title, a queue member,
/// no video on screen — must still reach the drift handlers, which reload for real drift.
///
/// Page loads are observed through a recording hook, so the integration cases need no live page.
@Suite(.serialized, .tags(.service))
@MainActor
struct SidebarVideoObservationTests {
    enum Setup: Sendable {
        case song
        case podcast
        case songVideoOff
        case songInQueue
    }

    struct FoldCase: CustomTestStringConvertible, Sendable {
        let name: String
        let setup: Setup
        let observedVideoId: String
        let title: String
        let artist: String
        let expected: String?

        var testDescription: String { self.name }
    }

    nonisolated static let foldContract: [FoldCase] = [
        FoldCase(
            name: "song: a same-title unknown id folds and is remembered",
            setup: .song, observedVideoId: "variant-9",
            title: "Song 1", artist: "Artist", expected: "song-1"
        ),
        FoldCase(
            name: "podcast: a same-title unknown id folds without being remembered",
            setup: .podcast, observedVideoId: "transient-9",
            title: "Episode 42", artist: "My Podcast", expected: "episode-42"
        ),
        FoldCase(
            name: "song: a different title is drift",
            setup: .song, observedVideoId: "variant-9",
            title: "Other Song", artist: "Artist", expected: nil
        ),
        FoldCase(
            name: "podcast: a different title is drift",
            setup: .podcast, observedVideoId: "transient-9",
            title: "Other Episode", artist: "My Podcast", expected: nil
        ),
        FoldCase(
            name: "a queue member is never folded",
            setup: .songInQueue, observedVideoId: "v2",
            title: "Song 2", artist: "", expected: nil
        ),
        FoldCase(
            name: "nothing folds while the sidebar video is off",
            setup: .songVideoOff, observedVideoId: "variant-9",
            title: "Song 1", artist: "Artist", expected: nil
        ),
    ]

    @Test(arguments: foldContract)
    func foldContractHolds(_ testCase: FoldCase) async {
        let player = self.makePlayer(testCase.setup)

        let folded = player.foldUnknownObservationIfSidebarSwitch(
            observedVideoId: testCase.observedVideoId,
            title: testCase.title,
            artist: testCase.artist
        )
        #expect(folded == testCase.expected, "\(testCase.name)")

        // A song's variant stays folded for late updates on that page; a podcast's
        // transient id is not a variant, so it is never remembered.
        let learned = testCase.setup == .song && folded != nil ? testCase.observedVideoId : nil
        #expect(player.observedVideoVariantVideoId == learned)
        if testCase.setup == .song, folded != nil {
            #expect(player.canonicalPlaybackVideoId(for: testCase.observedVideoId) == "song-1")
        }
    }

    @Test func aLearnedVariantIsTheOnlyExtraIdThatKeepsFolding() async {
        let player = self.makePlayer(.song)
        #expect(player.foldUnknownObservationIfSidebarSwitch(
            observedVideoId: "variant-9", title: "Song 1", artist: "Artist") == "song-1")
        // A second, different unknown id is genuine drift, learned variant or not.
        #expect(player.foldUnknownObservationIfSidebarSwitch(
            observedVideoId: "variant-10", title: "Song 1", artist: "Artist") == nil)
        #expect(player.canonicalPlaybackVideoId(for: "variant-10") == "variant-10")

        // And the learning ends with the song it belongs to.
        await player.play(song: Self.song("song-2", title: "Song 2", artist: "Artist 2"))
        #expect(player.canonicalPlaybackVideoId(for: "variant-9") == "variant-9")
    }

    // MARK: - Wiring Through the Observation Pipeline

    @Test func aTransientUnknownIdOnThePlayingPodcastDoesNotReload() async {
        let episodeId = "obs-episode-transient"
        let player = self.makePlayer(.podcast, id: episodeId)
        let log = Self.armLoadRecorder()
        defer { Self.disarmLoadRecorder() }

        player.updateTrackMetadata(
            title: "Episode 42", artist: "My Podcast", thumbnailUrl: "", videoId: "obs-episode-other-id"
        )
        await Self.settle()

        #expect(log.loads.allSatisfy { $0.videoId != episodeId })
        #expect(player.pendingPlayVideoId == episodeId)
        #expect(player.currentTrack?.videoId == episodeId)
    }

    @Test func aDifferentTrackStillRealignsThroughAReload() async {
        let episodeId = "obs-episode-drift"
        let player = self.makePlayer(.podcast, id: episodeId)
        let log = Self.armLoadRecorder()
        defer { Self.disarmLoadRecorder() }

        player.updateTrackMetadata(
            title: "Something Else Entirely", artist: "Another Show", thumbnailUrl: "", videoId: "obs-episode-new"
        )
        await Self.settle()

        #expect(log.loads.contains { $0.videoId == episodeId })
    }

    // MARK: - Fixtures

    private func makePlayer(_ setup: Setup, id: String? = nil) -> PlayerService {
        let player = PlayerService()
        switch setup {
        case .song, .songVideoOff:
            let song = Self.song(id ?? "song-1", title: "Song 1", artist: "Artist")
            player.queue = [song]
            player.currentIndex = 0
            player.currentTrack = song
            player.pendingPlayVideoId = song.videoId
            player.updateVideoAvailability(hasVideo: true)
            if setup == .song { player.toggleSidebarVideo() }
        case .podcast:
            let episode = Song(
                id: id ?? "episode-42",
                title: "Episode 42",
                artists: [Artist(id: "podcast", name: "My Podcast")],
                album: nil,
                duration: 1200,
                thumbnailURL: nil,
                videoId: id ?? "episode-42"
            )
            // Podcasts show video by default; `isCurrentTrackPodcast` comes from the artist.
            player.isSidebarVideoEnabled = true
            player.queue = [episode]
            player.currentIndex = 0
            player.currentTrack = episode
            player.pendingPlayVideoId = episode.videoId
            player.updateVideoAvailability(hasVideo: true)
        case .songInQueue:
            let songs = [
                Self.song("v1", title: "Song 1", artist: "Artist"),
                Self.song("v2", title: "Song 2", artist: "Artist"),
            ]
            player.queue = songs
            player.currentIndex = 0
            player.currentTrack = songs[0]
            player.pendingPlayVideoId = "v1"
            player.isSidebarVideoEnabled = true
            player.updateVideoAvailability(hasVideo: true)
        }
        return player
    }

    private static func song(_ id: String, title: String, artist: String) -> Song {
        Song(
            id: id, title: title,
            artists: [Artist(id: "artist-\(id)", name: artist)],
            album: nil, duration: 210, thumbnailURL: nil, videoId: id
        )
    }

    // MARK: - Load Recording

    private struct RecordedLoad: Equatable {
        let videoId: String
        let strategy: SingletonPlayerWebView.VideoLoadStrategy
    }

    /// All access is MainActor-serialized in practice (serialized suite, MainActor
    /// player and WebView); the unchecked conformance only satisfies the hook's
    /// nonisolated closure capture.
    private final class LoadLog: @unchecked Sendable {
        var loads: [RecordedLoad] = []
    }

    private static func armLoadRecorder() -> LoadLog {
        let log = LoadLog()
        SingletonPlayerWebView.shared.onPageLoadRequestForTests = { videoId, strategy in
            log.loads.append(RecordedLoad(videoId: videoId, strategy: strategy))
        }
        return log
    }

    private static func disarmLoadRecorder() {
        SingletonPlayerWebView.shared.onPageLoadRequestForTests = nil
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(400))
    }
}
