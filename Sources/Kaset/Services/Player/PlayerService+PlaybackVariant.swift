import Foundation

// MARK: - PlayerService + Playback Variant

/// A variant switch waiting for its page to load (see ``PlayerService/switchPlaybackVariant(toVideo:)``).
///
/// A switch loads a different upload of the same track, which begins at zero like any track load.
/// The position and the play state are carried here until the page that was loaded can take them.
struct PendingPlaybackVariantSeek {
    let videoId: String
    let position: TimeInterval
    let resumesPlayback: Bool
}

// MARK: - Playback Variant

/// Switches the player between a track's song and its music video.
///
/// The queue entry, its metadata, its artwork and its like/library state stay on the song: only
/// the page's stream changes. `canonicalPlaybackVideoId` folds the video page's id back onto the
/// song, so the observation pipeline does not read the switch as queue drift.
@MainActor
extension PlayerService {
    /// Whether `videoId` names the track that is playing, including its other variant.
    ///
    /// A list keeps the rows it was given: a YouTube-generated playlist lists the music video while
    /// the app plays its song, and the queue entry is the song. The two ids describe one track, so a
    /// row that is either side of the pairing is the playing row; comparing ids alone made the
    /// playlist stop showing which song is playing as soon as the variant was swapped.
    func isPlaybackTrack(videoId: String) -> Bool {
        guard let playingVideoId = self.currentTrack?.videoId else { return false }
        // The entry's own id folds to itself, so this covers both sides of the pairing.
        return self.canonicalPlaybackVideoId(for: videoId) == playingVideoId
    }

    /// The queue entry that is playing. The page may be on its other variant, so this is not
    /// necessarily the id the page was loaded with (see ``playbackPageVideoId(for:)``).
    var playbackItemVideoId: String? {
        self.currentTrack?.videoId ?? self.pendingPlayVideoId
    }

    /// The page id a song should be started with: its video while the sidebar is showing video,
    /// its song otherwise.
    func playbackPageVideoId(for song: Song) -> String {
        guard self.preferAudioVersions,
              self.isSidebarVideoEnabled,
              let videoVariant = self.variantMatcher.videoVariant(of: song)
        else { return song.videoId }
        return videoVariant.videoId
    }

    /// Plays the variant the sidebar asked for, from where the other one had got to.
    ///
    /// The page is loaded rather than asked to click YouTube's Song/Video tab: the tab is the
    /// page's own control, it moves the page onto a stream Kaset did not choose, and it is the
    /// reason the surface used to stay black when the tab could not be found. Loading the
    /// variant's page is the same switch, made by the app that owns playback.
    func switchPlaybackVariant(toVideo: Bool) {
        guard self.preferAudioVersions,
              let song = self.currentTrack
        else { return }

        // A pause that was waiting for the previous page must not fire on the page this switch is
        // about to load; the switch decides for itself whether the new page resumes.
        self.cancelPendingPauseIntent()

        let targetVideoId: String? = if toVideo {
            self.currentTrackVideoVariant?.videoId
        } else {
            self.audioPreferredVariant(song).videoId
        }

        let playingVideoId = self.pendingPlayVideoId ?? song.videoId
        guard let targetVideoId, targetVideoId != playingVideoId else { return }

        let resumes = self.isPlaying || self.state == .loading
        let position = self.progress

        // Stop watching the old track's start before the page changes under it.
        self.cancelPagePlaybackWatchdogs()
        self.pendingPlaybackVariantSeek = PendingPlaybackVariantSeek(
            videoId: targetVideoId,
            position: position,
            resumesPlayback: resumes
        )
        self.pendingPlayVideoId = targetVideoId
        self.state = resumes ? .loading : .paused
        // The verdict belongs to the page that now plays: a DOM scan of the other variant's page
        // must not hide the toggle halfway through the switch.
        self.updateVideoAvailabilityFromAPI(hasVideo: true, videoId: targetVideoId)
        self.logger.info(
            "Switching playback to the \(toVideo ? "video" : "song") variant \(targetVideoId) at \(Int(position))s"
        )
        SingletonPlayerWebView.shared.loadVideo(
            videoId: targetVideoId,
            strategy: .forceFullPageWhenSameVideoId
        )
    }

    /// Puts the listening position back after a variant page finishes loading.
    ///
    /// Called from the navigation delegate once the new document is up; the page applies the
    /// position as soon as its media can seek (see ``SingletonPlayerWebView/seekWhenReady(to:resumesPlayback:)``).
    func applyPendingPlaybackVariantSeek() {
        guard let pending = self.pendingPlaybackVariantSeek else { return }
        // Two toggles in quick succession replace the pending seek while the first document is still
        // loading. That first `didFinish` must not consume the second toggle's position — it is not
        // the page the seek belongs to — and the second `didFinish` is the one that applies it.
        guard self.pendingPlayVideoId == pending.videoId,
              SingletonPlayerWebView.shared.currentVideoId == pending.videoId
        else { return }
        self.pendingPlaybackVariantSeek = nil
        self.progress = pending.position
        // A pause during the load is the reader saying they are done listening for now.
        SingletonPlayerWebView.shared.seekWhenReady(
            to: pending.position,
            resumesPlayback: pending.resumesPlayback && self.state != .paused
        )
    }

    /// Forgets a pause that was waiting for a page to have media.
    ///
    /// Any command that asks for playback — a start, a resume, another variant switch — replaces
    /// that intent. The page-side poll is stopped as well, so a pause kept for a load cannot fire on
    /// a later track.
    func cancelPendingPauseIntent() {
        self.pauseWhenPageReady = false
        SingletonPlayerWebView.shared.cancelPauseWhenReady()
    }
}
