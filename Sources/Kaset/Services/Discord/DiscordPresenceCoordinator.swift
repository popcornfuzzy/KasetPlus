import Foundation
import Observation

// MARK: - DiscordPresenceCoordinator

/// Turns player state into a Discord card.
///
/// Polls `PlayerService` the way `ScrobblingCoordinator` does, but it needs none of the scrobble
/// bookkeeping: a card is a snapshot, so the only work is deciding when the snapshot changed
/// (a new track, play or pause, a seek, a duration that arrived late) and sending it once.
///
/// The progress bar is anchored to a playback session rather than to the poll: Discord draws the
/// timer from fixed `start`/`end` values, so re-sending them every 500 ms would be both pointless
/// and over the client's update rate limit.
@MainActor
@Observable
final class DiscordPresenceCoordinator {
    /// How often the player is read. Matches the scrobbling coordinator and `NotificationService`.
    static let pollInterval: Duration = .milliseconds(500)

    /// How long to wait before trying a Discord client that isn't there yet.
    static let reconnectInterval: TimeInterval = 5

    /// How far the position may drift before it counts as a seek rather than playing on.
    static let seekTolerance: TimeInterval = 3

    /// Discord rate-limits activity updates, so a refinements-only change waits for the next tick.
    /// A track change is not held back.
    private let minimumUpdateInterval: TimeInterval

    private let playerService: PlayerService
    private let settings: SettingsManager
    private let presence: any DiscordPresencePublishing
    private let logger = DiagnosticsLogger.discord

    private(set) var isMonitoring = false

    nonisolated(unsafe) private var pollingTask: Task<Void, Never>?

    // MARK: - Tracking State

    /// The track the current session belongs to.
    private var trackedVideoID: String?

    /// When this playback session began — the card's progress bar anchor.
    private var startedAt: Date?

    private var wasPlaying = false

    /// Where the next poll should find the playhead, to tell playing on from a seek.
    private var expectedProgress: TimeInterval = 0

    /// The card last sent, so an unchanged one is not sent again.
    private var published: DiscordActivity?

    private var publishedAt: Date?

    private var lastConnectAttempt: Date?

    // MARK: - Init

    init(
        playerService: PlayerService,
        settings: SettingsManager = .shared,
        presence: any DiscordPresencePublishing,
        minimumUpdateInterval: TimeInterval = 2
    ) {
        self.playerService = playerService
        self.settings = settings
        self.presence = presence
        self.minimumUpdateInterval = minimumUpdateInterval
    }

    // MARK: - Lifecycle

    func startMonitoring() {
        guard !self.isMonitoring else { return }
        self.isMonitoring = true
        self.logger.info("Discord presence coordinator started monitoring")

        self.pollingTask?.cancel()
        self.pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stopMonitoring() {
        self.pollingTask?.cancel()
        self.pollingTask = nil
        self.isMonitoring = false
        self.resetTracking()
        self.logger.info("Discord presence coordinator stopped monitoring")
    }

    // MARK: - Polling

    /// One pass over the player. Internal so tests can drive it without the timer.
    func poll() async {
        let now = Date()

        guard self.settings.discordRichPresenceEnabled else {
            if self.published != nil {
                self.published = nil
                await self.presence.publish(nil)
            }
            // Closes the socket when it is already open, and sets the status to `off`. Only asked
            // for when there is something to undo, so an idle app does not notify its views.
            if self.presence.status != .off {
                await self.presence.ensureConnected()
            }
            self.resetTracking()
            return
        }

        if !self.presence.status.isConnected,
           self.lastConnectAttempt.map({ now.timeIntervalSince($0) >= Self.reconnectInterval }) ?? true
        {
            self.lastConnectAttempt = now
            await self.presence.ensureConnected()
        }

        guard let track = self.playerService.currentTrack else {
            if self.published != nil {
                self.published = nil
                await self.presence.publish(nil)
            }
            self.resetTracking()
            return
        }

        let progress = self.playerService.progress
        let isPlaying = self.playerService.isPlaying
        let duration = track.duration ?? self.playerService.duration
        let trackChanged = track.videoId != self.trackedVideoID

        if trackChanged {
            self.trackedVideoID = track.videoId
            self.startedAt = now.addingTimeInterval(-progress)
        } else if isPlaying, !self.wasPlaying {
            // Resumed: the bar starts again from where the playhead is now.
            self.startedAt = now.addingTimeInterval(-progress)
        } else if isPlaying, abs(progress - self.expectedProgress) > Self.seekTolerance {
            // Sought: re-anchor so the bar does not run ahead of the audio.
            self.startedAt = now.addingTimeInterval(-progress)
        }

        self.wasPlaying = isPlaying
        self.expectedProgress = progress
        self.trackedVideoID = track.videoId

        let startedAt = self.startedAt ?? now.addingTimeInterval(-progress)
        guard let activity = DiscordActivity.nowPlaying(
            song: track,
            duration: duration,
            isPlaying: isPlaying,
            startedAt: startedAt
        ),
            activity != self.published
        else { return }

        if !trackChanged,
           let publishedAt = self.publishedAt,
           now.timeIntervalSince(publishedAt) < self.minimumUpdateInterval
        {
            return
        }

        self.published = activity
        self.publishedAt = now
        await self.presence.publish(activity)
    }

    private func resetTracking() {
        self.trackedVideoID = nil
        self.startedAt = nil
        self.wasPlaying = false
        self.expectedProgress = 0
        self.publishedAt = nil
    }
}
