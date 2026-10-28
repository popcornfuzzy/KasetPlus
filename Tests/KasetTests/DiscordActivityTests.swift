import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct DiscordActivityTests {
    // MARK: - Fixtures

    private func makeSong(
        title: String = "Blinding Lights",
        artists: [Artist] = [Artist(id: "UC1", name: "The Weeknd")],
        album: String? = "After Hours",
        duration: TimeInterval? = 200,
        artwork: String? = "https://i.ytimg.com/vi/video123/hqdefault.jpg",
        videoId: String = "video123"
    ) -> Song {
        Song(
            id: videoId,
            title: title,
            artists: artists,
            album: album.map { Album(id: "MPRE1", title: $0, artists: nil, thumbnailURL: nil, year: nil, trackCount: nil) },
            duration: duration,
            thumbnailURL: artwork.flatMap(URL.init(string:)),
            videoId: videoId
        )
    }

    // MARK: - Card Contents

    @Test("The card carries the track, the artists, the album and the artwork")
    func cardCarriesTrackMetadata() throws {
        let activity = try #require(
            DiscordActivity.nowPlaying(
                song: self.makeSong(),
                duration: 200,
                isPlaying: true,
                startedAt: Date(timeIntervalSince1970: 1000)
            )
        )

        #expect(activity.type == .listening)
        #expect(activity.details == "Blinding Lights")
        #expect(activity.state == "The Weeknd")
        // The album is the artwork's hover text, never part of the artist line.
        #expect(activity.assets?.largeText == "After Hours")
        #expect(activity.assets?.largeImage == "https://i.ytimg.com/vi/video123/hqdefault.jpg")
        #expect(activity.buttons?.first?.url == "https://music.youtube.com/watch?v=video123")
        #expect(activity.instance == false)
    }

    @Test("The card wears Kaset's icon and links to the repository")
    func cardCarriesKasetIconAndRepository() throws {
        let activity = try #require(
            DiscordActivity.nowPlaying(
                song: self.makeSong(),
                duration: 200,
                isPlaying: true,
                startedAt: Date()
            )
        )

        #expect(activity.assets?.smallImage == DiscordApplication.iconURL)
        #expect(activity.assets?.smallText == DiscordApplication.name)
        #expect(activity.buttons?.last?.label == "Kaset on GitHub")
        #expect(activity.buttons?.last?.url == DiscordApplication.repositoryURL)
    }

    @Test("A track with no YouTube id keeps the repository button")
    func repositoryButtonWithoutVideoID() throws {
        let activity = try #require(
            DiscordActivity.nowPlaying(
                song: self.makeSong(videoId: ""),
                duration: 200,
                isPlaying: true,
                startedAt: Date()
            )
        )

        #expect(activity.buttons?.map(\.url) == [DiscordApplication.repositoryURL])
    }

    @Test("Several artists are credited in one line")
    func severalArtistsJoined() throws {
        let activity = try #require(
            DiscordActivity.nowPlaying(
                song: self.makeSong(artists: [
                    Artist(id: "UC1", name: "Drake"),
                    Artist(id: "UC2", name: "Future"),
                ]),
                duration: 200,
                isPlaying: true,
                startedAt: Date()
            )
        )
        #expect(activity.state == "Drake, Future")
    }

    @Test("A track without artists has no artist line")
    func missingArtistsOmitted() throws {
        let activity = try #require(
            DiscordActivity.nowPlaying(
                song: self.makeSong(artists: []),
                duration: 200,
                isPlaying: true,
                startedAt: Date()
            )
        )
        #expect(activity.state == nil)
    }

    @Test("A track without an album has no hover text")
    func missingAlbumOmitted() throws {
        let activity = try #require(
            DiscordActivity.nowPlaying(
                song: self.makeSong(album: nil),
                duration: 200,
                isPlaying: true,
                startedAt: Date()
            )
        )
        #expect(activity.assets?.largeText == nil)
    }

    @Test("An untitled track produces no card")
    func emptyTitleProducesNoCard() {
        let activity = DiscordActivity.nowPlaying(
            song: self.makeSong(title: "   "),
            duration: 200,
            isPlaying: true,
            startedAt: Date()
        )
        #expect(activity == nil)
    }

    // MARK: - Progress Bar

    @Test("Playing anchors the progress bar to the start and the end of the session")
    func playingAnchorsTimestamps() throws {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let activity = try #require(
            DiscordActivity.nowPlaying(
                song: self.makeSong(duration: 200),
                duration: 200,
                isPlaying: true,
                startedAt: startedAt
            )
        )

        #expect(activity.timestamps?.start == 1_000_000)
        #expect(activity.timestamps?.end == 1_200_000)
    }

    @Test("A paused track carries no timestamps, so Discord cannot count on")
    func pausedHasNoTimestamps() throws {
        let activity = try #require(
            DiscordActivity.nowPlaying(
                song: self.makeSong(),
                duration: 200,
                isPlaying: false,
                startedAt: Date(timeIntervalSince1970: 1_000)
            )
        )
        #expect(activity.timestamps == nil)
    }

    @Test("An unknown duration leaves the progress bar open-ended")
    func unknownDurationHasNoEnd() throws {
        let activity = try #require(
            DiscordActivity.nowPlaying(
                song: self.makeSong(duration: nil),
                duration: 0,
                isPlaying: true,
                startedAt: Date(timeIntervalSince1970: 1_000)
            )
        )
        #expect(activity.timestamps?.start == 1_000_000)
        #expect(activity.timestamps?.end == nil)
    }

    // MARK: - Limits

    @Test("Texts are clipped to Discord's limit")
    func longTextIsClipped() throws {
        let long = String(repeating: "a", count: 300)
        let activity = try #require(
            DiscordActivity.nowPlaying(
                song: self.makeSong(title: long, artists: [Artist(id: "UC1", name: long)]),
                duration: 200,
                isPlaying: true,
                startedAt: Date()
            )
        )
        #expect(activity.details.count == DiscordActivity.textLimit)
        #expect(activity.state?.count == DiscordActivity.textLimit)
    }
}
