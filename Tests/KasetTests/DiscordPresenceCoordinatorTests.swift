import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct DiscordPresenceCoordinatorTests {
    // MARK: - Fake Publisher

    /// Records what the coordinator asked Discord to show.
    @MainActor
    private final class FakePresence: DiscordPresencePublishing {
        var status: DiscordPresenceStatus = .connected
        private(set) var published: [DiscordActivity?] = []
        private(set) var ensureConnectedCalls = 0
        private(set) var clearCount = 0

        func ensureConnected() async {
            self.ensureConnectedCalls += 1
        }

        func publish(_ activity: DiscordActivity?) async {
            if activity == nil {
                self.clearCount += 1
            }
            self.published.append(activity)
        }

        var lastActivity: DiscordActivity? {
            self.published.last ?? nil
        }
    }

    // MARK: - Helpers

    private func makeSong(
        title: String = "Blinding Lights",
        artist: String = "The Weeknd",
        duration: TimeInterval? = 200,
        videoId: String = "video123"
    ) -> Song {
        Song(
            id: videoId,
            title: title,
            artists: [Artist(id: "UC1", name: artist)],
            duration: duration,
            videoId: videoId
        )
    }

    /// Enables presence for the duration of a test, restoring the previous value afterwards.
    private func withPresenceEnabled<T>(_ body: () async throws -> T) async rethrows -> T {
        let previous = SettingsManager.shared.discordRichPresenceEnabled
        SettingsManager.shared.discordRichPresenceEnabled = true
        defer { SettingsManager.shared.discordRichPresenceEnabled = previous }
        return try await body()
    }

    private func makeCoordinator(
        player: PlayerService,
        presence: FakePresence
    ) -> DiscordPresenceCoordinator {
        // No update throttle, so a test can drive several polls without waiting.
        DiscordPresenceCoordinator(playerService: player, presence: presence, minimumUpdateInterval: 0)
    }

    // MARK: - Polling

    @Test("A playing track is published once, not once per poll")
    func oneActivityPerTrack() async throws {
        try await self.withPresenceEnabled {
            let player = PlayerService()
            let presence = FakePresence()
            let coordinator = self.makeCoordinator(player: player, presence: presence)

            player.currentTrack = self.makeSong()
            player.progress = 0
            player.state = .playing

            await coordinator.poll()
            await coordinator.poll()
            await coordinator.poll()

            #expect(presence.published.count == 1)
            #expect(presence.lastActivity?.details == "Blinding Lights")
            #expect(presence.lastActivity?.state == "The Weeknd")
            #expect(presence.lastActivity?.timestamps != nil)
        }
    }

    @Test("Pausing drops the progress bar")
    func pauseDropsTimestamps() async throws {
        try await self.withPresenceEnabled {
            let player = PlayerService()
            let presence = FakePresence()
            let coordinator = self.makeCoordinator(player: player, presence: presence)

            player.currentTrack = self.makeSong()
            player.progress = 10
            player.state = .playing
            await coordinator.poll()
            #expect(presence.lastActivity?.timestamps != nil)

            player.state = .paused
            await coordinator.poll()
            #expect(presence.published.count == 2)
            #expect(presence.lastActivity?.timestamps == nil)
        }
    }

    @Test("A seek re-anchors the progress bar")
    func seekReanchorsTimestamps() async throws {
        try await self.withPresenceEnabled {
            let player = PlayerService()
            let presence = FakePresence()
            let coordinator = self.makeCoordinator(player: player, presence: presence)

            player.currentTrack = self.makeSong()
            player.progress = 5
            player.state = .playing
            await coordinator.poll()
            let firstStart = try #require(presence.lastActivity?.timestamps?.start)

            player.progress = 120
            await coordinator.poll()
            let secondStart = try #require(presence.lastActivity?.timestamps?.start)

            // Jumping forward moves the session's start with it, so the bar matches the audio.
            #expect(secondStart < firstStart)
        }
    }

    @Test("An emptied player clears the card")
    func clearingPublishesNil() async throws {
        try await self.withPresenceEnabled {
            let player = PlayerService()
            let presence = FakePresence()
            let coordinator = self.makeCoordinator(player: player, presence: presence)

            player.currentTrack = self.makeSong()
            player.state = .playing
            await coordinator.poll()
            #expect(presence.published.count == 1)

            player.currentTrack = nil
            player.state = .idle
            await coordinator.poll()

            #expect(presence.published.count == 2)
            #expect(presence.clearCount == 1)
        }
    }

    @Test("Switching presence off clears the card and stops connecting")
    func disabledClearsAndDoesNotPublish() async throws {
        let previous = SettingsManager.shared.discordRichPresenceEnabled
        SettingsManager.shared.discordRichPresenceEnabled = false
        defer { SettingsManager.shared.discordRichPresenceEnabled = previous }

        let player = PlayerService()
        let presence = FakePresence()
        let coordinator = self.makeCoordinator(player: player, presence: presence)

        player.currentTrack = self.makeSong()
        player.state = .playing
        await coordinator.poll()

        #expect(presence.published.isEmpty)
        #expect(presence.ensureConnectedCalls == 1)
    }

    @Test("A Discord client that is not running is retried, not hammered")
    func reconnectIsThrottled() async throws {
        try await self.withPresenceEnabled {
            let player = PlayerService()
            let presence = FakePresence()
            presence.status = .waitingForDiscord
            let coordinator = self.makeCoordinator(player: player, presence: presence)

            await coordinator.poll()
            await coordinator.poll()

            #expect(presence.ensureConnectedCalls == 1)
        }
    }
}
