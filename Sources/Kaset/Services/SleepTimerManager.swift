import Foundation
import Observation

// MARK: - SleepTimerManager

/// Pauses playback after a chosen number of minutes.
///
/// Offered from the Playback menu rather than the player bar: it is a set-and-forget action, not a
/// control the reader touches mid-song, and the bar stays reserved for what is playing.
@MainActor
@Observable
final class SleepTimerManager {
    static let shared = SleepTimerManager()

    /// The durations offered in the Playback menu, in minutes.
    static let options = [5, 15, 30, 45, 60]

    /// The duration the running timer was started with, for the menu's checkmark.
    private(set) var activeMinutes: Int?

    /// When the running timer fires.
    private(set) var endDate: Date?

    private var timerTask: Task<Void, Never>?
    private let logger = DiagnosticsLogger.player

    var isActive: Bool {
        self.endDate != nil
    }

    /// Starts (or restarts) the timer, pausing `player` when it expires.
    func start(minutes: Int, player: PlayerService) {
        self.cancel()

        let deadline = Date().addingTimeInterval(Double(minutes) * 60)
        self.activeMinutes = minutes
        self.endDate = deadline
        self.logger.info("Sleep timer started: \(minutes) minutes")

        self.timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled, let self, self.endDate == deadline else { return }

            await player.pause()
            self.logger.info("Sleep timer expired; playback paused")
            self.activeMinutes = nil
            self.endDate = nil
            self.timerTask = nil
        }
    }

    func cancel() {
        self.timerTask?.cancel()
        self.timerTask = nil
        self.activeMinutes = nil
        self.endDate = nil
    }
}
