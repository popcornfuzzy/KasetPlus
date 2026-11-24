import AppKit
import Foundation
import MediaPlayer
import Observation
import os

/// Manages remote command center integration for media key support, and keeps the system's Now
/// Playing panel on the track Kaset is playing.
///
/// macOS reads WKWebView's media session as the app's player, so the panel is WebKit's — YouTube Music
/// writes that session from its own state, which is exactly what the panel must not show while the page
/// plays Kaset's queue. Two things are therefore pinned at document start: the session's metadata to
/// `currentTrack` (see `nowPlayingMetadataScript`) and its Next/Previous actions to Kaset's queue (see
/// `mediaControlOverrideScript`), so the system's buttons belong to the queue with or without a window
/// on screen. Kaset deliberately publishes no `MPNowPlayingInfoCenter` entry of its own: WebKit's card
/// is a separate Now Playing client, and a second publisher is a second row in the panel (ADR-0038).
@MainActor
@Observable
final class NowPlayingManager {
    /// Shared singleton instance. Must be configured with `configure(playerService:)` before use.
    static let shared = NowPlayingManager()

    private var playerService: PlayerService?
    private let logger = DiagnosticsLogger.player
    private var isConfigured = false
    private let settings = SettingsManager.shared

    private init() {}

    /// Configures the singleton with a player service. Only configures once; subsequent calls are ignored.
    func configure(playerService: PlayerService) {
        guard !self.isConfigured else {
            self.logger.debug("NowPlayingManager already configured, skipping")
            return
        }
        self.isConfigured = true
        self.playerService = playerService
        self.setupRemoteCommands()
        self.syncMediaControlSetting()
        self.logger.info("NowPlayingManager configured (remote commands, Now Playing metadata)")

        self.observeSettingsChanges()
        self.observeNowPlayingMetadata()
    }

    /// Keeps WebKit's Now Playing card on the track Kaset is playing.
    ///
    /// Every change of `currentTrack` — a start, an advance, the page's refined byline, or the album
    /// art arriving with fetched metadata — is pushed to the media session; the session's pin drops
    /// whatever the page writes there afterwards. `nil` (nothing playing, or only the "Loading..."
    /// placeholder) clears the entry instead of describing a song that is not the one playing.
    private func observeNowPlayingMetadata() {
        // Read only inside the tracked closure, and push outside it. Pushing from in here ran
        // WebKit's message pump inside the access-list scope, and every task a message handler
        // spawned on the way inherited a pointer to that scope's list — which is gone by the time
        // the task runs. That is the `_AccessList.addAccess` crash: see
        // `docs/common-bug-patterns.md`.
        let track = self.playerService?.currentTrack
        withObservationTracking {
            _ = self.playerService?.currentTrack
        } onChange: {
            // Detached on purpose: `Task {}` here would inherit the task-local access list of
            // whatever mutated the track, and that list belongs to a scope that has returned.
            Task.detached { @MainActor [weak self] in
                self?.observeNowPlayingMetadata()
            }
        }
        self.pushNowPlayingMetadata(for: track)
    }

    /// Re-pushes the current track.
    ///
    /// A page load replaces the media session, and with it the pin, so whatever the app last pushed
    /// has to be pushed again — otherwise the first track after a navigation is described by the page.
    func refreshNowPlayingMetadata() {
        self.pushNowPlayingMetadata(for: self.playerService?.currentTrack)
    }

    private func pushNowPlayingMetadata(for track: Song?) {
        guard let track else {
            SingletonPlayerWebView.shared.clearNowPlayingMetadata()
            return
        }
        // A start seeds `currentTrack` with the "Loading..." placeholder; pushing that would blank the
        // panel for the length of the start. The last real description stays until this track has one.
        guard let metadata = WebNowPlayingMetadata(song: track) else { return }
        SingletonPlayerWebView.shared.applyNowPlayingMetadata(metadata)
    }

    private func observeSettingsChanges() {
        withObservationTracking {
            _ = self.settings.mediaControlStyle
        } onChange: {
            // Detached: a `Task {}` made here inherits the access list of the scope the mutation
            // happened in, and that list does not outlive it (see `observeNowPlayingMetadata`).
            Task.detached { @MainActor [weak self] in
                self?.syncMediaControlSetting()
                self?.observeSettingsChanges()
            }
        }
    }

    /// Syncs the media control style setting to the singleton WebView and its bootstrap state.
    private func syncMediaControlSetting() {
        let useNextPrev = self.settings.mediaControlStyle == .nextPreviousTrack
        SingletonPlayerWebView.shared.setMediaControlStyle(useNextPrev: useNextPrev)
    }

    // MARK: - Remote Commands

    private func setupRemoteCommands() {
        guard let player = playerService else { return }
        let commandCenter = MPRemoteCommandCenter.shared()
        // Remove any existing targets to prevent duplicates
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { _ in
            Task { @MainActor in
                await player.resume()
            }
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { _ in
            Task { @MainActor in
                await player.pause()
            }
            return .success
        }

        // Toggle play/pause command
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in
                await player.playPause()
            }
            return .success
        }

        // Next track command
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { _ in
            Task { @MainActor in
                await player.nextFromRemoteControl()
            }
            return .success
        }

        // Previous track command
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { _ in
            Task { @MainActor in
                await player.previousFromRemoteControl()
            }
            return .success
        }

        // Change playback position command
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            Task { @MainActor in
                await player.seek(to: position)
            }
            return .success
        }

        self.logger.info("Remote commands configured")
    }
}
