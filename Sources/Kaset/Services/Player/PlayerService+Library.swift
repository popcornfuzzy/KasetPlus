import Foundation

// MARK: - Like/Dislike/Library Actions

@MainActor
extension PlayerService {
    /// Likes the current track (thumbs up).
    /// Delegates to SongLikeStatusManager for unified state management and real-time sync.
    func likeCurrentTrack() {
        guard let track = currentTrack else { return }
        self.logger.info("Liking current track: \(track.videoId)")
        let activeAccountID = SongLikeStatusManager.shared.activeAccountID
        let client = self.ytMusicClient
        // Fix the coalescing window at click time so the whole burst uses one value.
        let debounce = SongLikeStatusManager.shared.ratingDebounce

        // Toggle: if already liked, remove the like
        let newStatus: LikeStatus = self.currentTrackLikeStatus == .like ? .indifferent : .like
        // Optimistic UI update for PlayerBar
        self.currentTrackLikeStatus = newStatus

        // Delegate to SongLikeStatusManager for API call + cache sync + event emission
        Task {
            let finalStatus: LikeStatus = if newStatus == .like {
                await SongLikeStatusManager.shared.like(
                    track,
                    accountID: activeAccountID,
                    client: client,
                    debounce: debounce
                )
            } else {
                await SongLikeStatusManager.shared.unlike(
                    track,
                    accountID: activeAccountID,
                    client: client,
                    debounce: debounce
                )
            }

            guard SongLikeStatusManager.shared.activeAccountID == activeAccountID,
                  self.currentTrack?.videoId == track.videoId
            else {
                return
            }

            // rate() settles to the cache-current status (latest intent wins), so this
            // write is idempotent; skip it when the value is unchanged to avoid pointless
            // observation notifications during rapid clicks.
            guard self.currentTrackLikeStatus != finalStatus else { return }
            self.currentTrackLikeStatus = finalStatus
        }
    }

    /// Dislikes the current track (thumbs down).
    /// Delegates to SongLikeStatusManager for unified state management and real-time sync.
    func dislikeCurrentTrack() {
        guard let track = currentTrack else { return }
        self.logger.info("Disliking current track: \(track.videoId)")
        let activeAccountID = SongLikeStatusManager.shared.activeAccountID
        let client = self.ytMusicClient
        // Fix the coalescing window at click time so the whole burst uses one value.
        let debounce = SongLikeStatusManager.shared.ratingDebounce

        // Toggle: if already disliked, remove the dislike
        let newStatus: LikeStatus = self.currentTrackLikeStatus == .dislike ? .indifferent : .dislike
        // Optimistic UI update for PlayerBar
        self.currentTrackLikeStatus = newStatus

        // Delegate to SongLikeStatusManager for API call + cache sync + event emission
        Task {
            let finalStatus: LikeStatus = if newStatus == .dislike {
                await SongLikeStatusManager.shared.dislike(
                    track,
                    accountID: activeAccountID,
                    client: client,
                    debounce: debounce
                )
            } else {
                await SongLikeStatusManager.shared.undislike(
                    track,
                    accountID: activeAccountID,
                    client: client,
                    debounce: debounce
                )
            }

            guard SongLikeStatusManager.shared.activeAccountID == activeAccountID,
                  self.currentTrack?.videoId == track.videoId
            else {
                return
            }

            // Idempotent write; see likeCurrentTrack().
            guard self.currentTrackLikeStatus != finalStatus else { return }
            self.currentTrackLikeStatus = finalStatus
        }
    }

    /// Toggles the library status of the current track.
    func toggleLibraryStatus() {
        guard let track = currentTrack else { return }
        self.logger.info("Toggling library status for current track: \(track.videoId)")
        let activeAccountID = SongLikeStatusManager.shared.activeAccountID

        // Determine which token to use based on current state
        let isCurrentlyInLibrary = self.currentTrackInLibrary
        let tokenToUse = isCurrentlyInLibrary
            ? self.currentTrackFeedbackTokens?.remove
            : self.currentTrackFeedbackTokens?.add

        guard let token = tokenToUse else {
            self.logger.warning("No feedback token available for library toggle")
            return
        }

        // Optimistic update
        let previousState = self.currentTrackInLibrary
        let previousTokens = self.currentTrackFeedbackTokens
        let expectedInLibrary = !isCurrentlyInLibrary
        let expectedFeedbackTokens = FeedbackTokens(
            add: previousTokens?.remove,
            remove: previousTokens?.add
        )
        self.updateCurrentTrackLibraryState(
            isInLibrary: expectedInLibrary,
            feedbackTokens: expectedFeedbackTokens
        )

        // Use API call for reliable library management
        Task {
            do {
                try await self.ytMusicClient?.editSongLibraryStatus(feedbackTokens: [token])
                let action = isCurrentlyInLibrary ? "removed from" : "added to"
                self.logger.info("Successfully \(action) library")

                // After successful toggle, we need to swap the tokens
                // The browse metadata can lag briefly, so delay the refresh and keep
                // the optimistic library state if the response is still stale.
                try? await Task.sleep(for: .milliseconds(500))

                guard SongLikeStatusManager.shared.activeAccountID == activeAccountID else { return }

                await self.fetchSongMetadata(videoId: track.videoId)

                guard SongLikeStatusManager.shared.activeAccountID == activeAccountID,
                      self.currentTrack?.videoId == track.videoId
                else {
                    return
                }

                if self.currentTrackInLibrary != expectedInLibrary {
                    self.updateCurrentTrackLibraryState(
                        isInLibrary: expectedInLibrary,
                        feedbackTokens: expectedFeedbackTokens
                    )
                }
            } catch {
                self.logger.error("Failed to toggle library status: \(error.localizedDescription)")
                // Revert on failure
                guard SongLikeStatusManager.shared.activeAccountID == activeAccountID,
                      self.currentTrack?.videoId == track.videoId
                else {
                    return
                }

                self.updateCurrentTrackLibraryState(
                    isInLibrary: previousState,
                    feedbackTokens: previousTokens
                )
            }
        }
    }

    /// Updates the like status from the transport's own like button, as the WebView observed it.
    ///
    /// The observation is only taken when it can be attributed to the track this service holds: the
    /// player bar's button describes the video *the bar names*, and the bar lags an in-page track
    /// change. A status read while the bar still names the song that was just left is that song's
    /// rating, and taking it lit the new track's thumb for a song nobody had liked — for the whole
    /// song, because every later answer was read as unknown rather than as "not rated".
    ///
    /// `INDIFFERENT` stays untrusted even when anchored: the button's attribute is absent until the
    /// bar renders it, and a missing attribute is not a removed rating. The record
    /// (`fetchSongMetadata`) is what says which one it is.
    ///
    /// - Parameters:
    ///   - status: The status the bar's like button renders.
    ///   - videoId: The video the player holds, when the page reports it.
    ///   - playerBarVideoId: The video the player bar itself names, when the page reports it.
    ///   - metadataFromPlayer: Whether the bar's title was too stale to be believed.
    func updateLikeStatus(
        _ status: LikeStatus,
        videoId: String?,
        playerBarVideoId: String?,
        metadataFromPlayer: Bool
    ) {
        // The bar's text lagging means its button lags with it (see `updateTrackMetadata`).
        guard !metadataFromPlayer else { return }

        if let videoId {
            let observedVideoId = self.canonicalPlaybackVideoId(for: videoId) ?? videoId
            // The button belongs to the video the bar names. A bar naming another track, or no bar
            // link at all, cannot attribute the status to anything.
            guard let playerBarVideoId, !playerBarVideoId.isEmpty,
                  (self.canonicalPlaybackVideoId(for: playerBarVideoId) ?? playerBarVideoId) == observedVideoId
            else { return }
            // And it may only ever become *this* track's status, never the one about to replace it.
            guard let currentVideoId = self.currentTrack?.videoId, currentVideoId == observedVideoId else { return }
        }

        guard status != .indifferent else { return }

        // The cache is the newer word on this song (every settled rating and every fetched record
        // writes it), so it outranks a rendering.
        if let videoId, let cachedStatus = SongLikeStatusManager.shared.status(for: videoId) {
            self.currentTrackLikeStatus = cachedStatus
        } else {
            self.currentTrackLikeStatus = status
        }
    }

    /// Resets like/library status when track changes.
    func resetTrackStatus() {
        self.currentTrackLikeStatus = .indifferent
        self.currentTrackInLibrary = false
        self.currentTrackFeedbackTokens = nil
    }

    private func updateCurrentTrackLibraryState(
        isInLibrary: Bool,
        feedbackTokens: FeedbackTokens?
    ) {
        self.currentTrackInLibrary = isInLibrary
        self.currentTrackFeedbackTokens = feedbackTokens

        guard var currentTrack = self.currentTrack else { return }
        currentTrack.isInLibrary = isInLibrary
        currentTrack.feedbackTokens = feedbackTokens
        self.currentTrack = currentTrack
    }

    /// Asks YouTube Music for the structured record of the playing track — once per video.
    ///
    /// The WebView's byline is a *rendering*, not a record: it names the track in one string, without
    /// artist IDs, without the album, and with no like or library state. `getSong` asks the `next`
    /// endpoint, which is what YouTube Music itself knows about the video — the same call a track played
    /// from a page already makes. A track YouTube started on its own (autoplay after the queue, a radio
    /// station, a restored session) never went through `play(song:)`, so nothing asked for it before and
    /// the transport had no like or library state to show. That is the gap this closes.
    ///
    /// A track whose row already carries all of it costs no request: the guard is the data, not the
    /// caller. One request per video, cached by `APICache.TTL.songMetadata`.
    func enrichSongMetadataIfNeeded(videoId: String) {
        guard self.currentTrack?.videoId == videoId else { return }
        guard self.songMetadataRequestedVideoId != videoId else { return }

        let track = self.currentTrack
        let hasStructuredArtists = track?.artists.contains { $0.hasNavigableId } ?? false
        let hasState = track?.likeStatus != nil && track?.isInLibrary != nil && track?.feedbackTokens != nil
        guard !hasStructuredArtists || !hasState else { return }

        self.songMetadataRequestedVideoId = videoId
        Task { @MainActor [weak self] in
            await self?.fetchSongMetadata(videoId: videoId)
        }
    }

    /// Fetches full song metadata including feedbackTokens from the API.
    func fetchSongMetadata(videoId: String) async {
        guard let client = ytMusicClient else {
            self.logger.warning("No YTMusicClient available for fetching song metadata")
            return
        }

        let activeAccountID = SongLikeStatusManager.shared.activeAccountID

        do {
            let songData = try await client.getSong(videoId: videoId)
            guard SongLikeStatusManager.shared.activeAccountID == activeAccountID else { return }

            // The record is the authority on the rating: it is YouTube Music's own state for this
            // video, and it separates "not rated" (`.indifferent`) from "not known" (the response
            // carries no like button, so the parser answers nil). Reading its `.indifferent` as
            // unknown is what let a surface's guess stand for good.
            //
            // One thing outranks it: a rating the user made in this session. The response can predate
            // the click — `next` answers are cached for `APICache.TTL.songMetadata` — and applying it
            // would undo the click.
            let cachedLikeStatus = SongLikeStatusManager.shared.status(for: videoId)
            let recordLikeStatus = songData.likeStatus
            let resolvedLikeStatus: LikeStatus? = if SongLikeStatusManager.shared.hasUserRating(for: videoId) {
                cachedLikeStatus ?? recordLikeStatus
            } else {
                recordLikeStatus ?? cachedLikeStatus
            }

            // Update current track with full metadata if it's still the same song
            if self.currentTrack?.videoId == videoId {
                // Preserve the title/artist from WebView if they're better
                let title = self.currentTrack?.title == "Loading..." ? songData.title : (self.currentTrack?.title ?? songData.title)
                // ...but not a byline that carries no identity: the WebView reports every name in one
                // artist without a channel ID, while the API's artists are the ones that can be opened.
                // The same rule turns an "Unknown Artist" placeholder into the real credit.
                let currentArtists = self.currentTrack?.artists ?? []
                let artists: [Artist] = if currentArtists.contains(where: { $0.hasNavigableId }) {
                    currentArtists
                } else if !songData.artists.isEmpty {
                    songData.artists
                } else {
                    currentArtists
                }

                // The video variant of a matched song is the counterpart Kaset keeps for PiP.
                if self.preferAudioVersions,
                   self.currentTrackVideoVariant == nil,
                   let counterpart = songData.counterpart, counterpart.isVideoVariant
                {
                    self.currentTrackVideoVariant = counterpart.asSong
                }

                self.currentTrack = Song(
                    id: videoId,
                    title: title,
                    artists: artists,
                    album: songData.album ?? self.currentTrack?.album,
                    duration: songData.duration ?? self.currentTrack?.duration,
                    // Keep the artwork that is already on screen: `getSong` returns the same picture
                    // under a rotated signature/size URL, so replacing it would reload the image for
                    // the song that is already playing (visible flicker in the now-playing artwork)
                    // and would hand the artwork view a URL this song never displayed before.
                    thumbnailURL: self.currentTrack?.thumbnailURL ?? songData.thumbnailURL,
                    videoId: videoId,
                    musicVideoType: songData.musicVideoType,
                    counterpart: self.currentTrackVideoVariant.map { SongCounterpart(song: $0) } ?? self.currentTrack?.counterpart,
                    likeStatus: resolvedLikeStatus,
                    isInLibrary: songData.isInLibrary,
                    feedbackTokens: songData.feedbackTokens
                )

                // Apply the answer to the bar's state and to the cache, so the correction reaches
                // every surface that reads the rating. `.indifferent` is an answer, not a gap, so it
                // is written too; only a record with no like button at all leaves the cache alone.
                if let resolvedLikeStatus {
                    self.currentTrackLikeStatus = resolvedLikeStatus
                    SongLikeStatusManager.shared.setStatus(resolvedLikeStatus, for: videoId)
                }
                self.currentTrackInLibrary = songData.isInLibrary ?? false
                self.currentTrackFeedbackTokens = songData.feedbackTokens

                // Update video availability based on API-detected musicVideoType
                // This is more reliable than DOM inspection since it comes directly from the API.
                // A known video counterpart also counts: the song plays, but the PiP miniplayer
                // can switch to the music video.
                let hasVideoVariant = self.currentTrackVideoVariant != nil
                    || (songData.counterpart?.isVideoVariant ?? false)
                if let videoType = songData.musicVideoType {
                    let hasVideo = videoType.hasVideoContent || hasVideoVariant
                    self.updateVideoAvailabilityFromAPI(hasVideo: hasVideo, videoId: videoId)
                    self.logger.debug("Video availability from API: \(videoType.rawValue) -> hasVideo=\(hasVideo)")
                } else if hasVideoVariant {
                    self.updateVideoAvailabilityFromAPI(hasVideo: true, videoId: videoId)
                }

                self.logger.info("Updated track metadata - inLibrary: \(self.currentTrackInLibrary), hasTokens: \(self.currentTrackFeedbackTokens != nil)")

                // Also update the corresponding song in the queue with enriched metadata
                // This ensures the queue displays complete info without separate API calls
                if let queueIndex = self.queue.firstIndex(where: { $0.videoId == videoId }) {
                    // Only update if the queue entry is missing metadata
                    let currentQueueSong = self.queue[queueIndex]
                    let needsUpdate = currentQueueSong.artists.isEmpty ||
                        currentQueueSong.artists.allSatisfy { $0.name.isEmpty || $0.name == "Unknown Artist" } ||
                        currentQueueSong.title.isEmpty ||
                        currentQueueSong.title == "Loading..." ||
                        currentQueueSong.thumbnailURL == nil

                    if needsUpdate {
                        var enrichedQueueSong = songData
                        enrichedQueueSong.likeStatus = resolvedLikeStatus
                        self.queue[queueIndex] = enrichedQueueSong
                        self.logger.debug("Enriched queue entry at index \(queueIndex): '\(enrichedQueueSong.title)' with artists: \(enrichedQueueSong.artistsDisplay)")
                        // Save the enriched queue to persistence
                        self.saveQueueForPersistence()
                    }
                }
            }
        } catch {
            self.logger.warning("Failed to fetch song metadata: \(error.localizedDescription)")
        }
    }
}
