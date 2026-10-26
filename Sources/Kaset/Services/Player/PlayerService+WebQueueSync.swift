import Foundation

// MARK: - Web Queue Sync

@MainActor
extension PlayerService {
    /// Artwork resolution for an observation: a picture we already hold for this video wins over the
    /// WebView's player-bar `<img src>`.
    ///
    /// The observed URL is the *same* artwork from a differently signed/sized URL, and YouTube rewrites
    /// it while it upgrades the image — and at launch, before the page has rendered the track, the
    /// player bar can still hold a placeholder or the previous song's picture. Adopting it therefore
    /// churns `currentTrack` for no new content (visible flicker) and can hand the artwork views a URL
    /// that never resolves (a blank now-playing picture until something else re-points the track).
    /// The observation is only a fallback for artwork we do not have yet: the current track's own
    /// picture, then the queue entry for the same video, then — last — what the WebView reported.
    private func resolvedThumbnailURL(observed thumbnailUrl: String?, videoId: String) -> URL? {
        if self.currentTrack?.videoId == videoId, let artwork = self.currentTrack?.thumbnailURL {
            return artwork
        }
        if let queuedArtwork = self.queue.first(where: { $0.videoId == videoId })?.thumbnailURL {
            return queuedArtwork
        }
        return self.normalizedThumbnailURL(thumbnailUrl) ?? self.currentTrack?.thumbnailURL
    }

    /// Whether an observation that is *not* a track change still has to be reconciled because it
    /// carries artwork the playing track is missing.
    ///
    /// A song that starts while the WebView is still opening can end up without a picture:
    /// ``fetchSongMetadata`` can lose the race against account initialization, and the player bar
    /// `<img>` is empty until the page renders the track. The observer's state updates carry that
    /// picture as soon as the WebView has it, but ``updateTrackMetadata`` only ran on a *track change*,
    /// so the artwork of the song that is playing stayed blank for its whole length.
    ///
    /// Only an observation of the same video that we already consider equivalent to the playing track
    /// qualifies: that is the path that keeps our richer metadata and takes the WebView's picture only
    /// because we have none.
    func shouldReconcileMissingArtwork(
        observedVideoId: String?,
        title: String,
        artist: String,
        thumbnailUrl: String
    ) -> Bool {
        guard let track = self.currentTrack,
              track.thumbnailURL == nil,
              let observedVideoId = self.normalizedObservedVideoId(observedVideoId),
              observedVideoId == track.videoId,
              self.normalizedThumbnailURL(thumbnailUrl) != nil
        else {
            return false
        }
        return self.metadataMatchesSong(title: title, artist: artist, song: track)
    }

    private func normalizedThumbnailURL(_ thumbnailUrl: String?) -> URL? {
        guard let thumbnailUrl else { return nil }
        let trimmed = thumbnailUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return nil }
        return URL(string: trimmed)
    }

    private func normalizedObservedVideoId(_ videoId: String?) -> String? {
        guard let videoId, !videoId.isEmpty else { return nil }
        return videoId
    }

    private func resolvedObservedVideoId(_ videoId: String?) -> String {
        self.normalizedObservedVideoId(videoId) ?? self.currentTrack?.videoId ?? self.pendingPlayVideoId ?? "unknown"
    }

    /// Folds a WebView observation of the paired *video* variant onto the song entry that is
    /// playing.
    ///
    /// Kaset plays the song version; the PiP miniplayer can switch YouTube's page to the music
    /// video, after which the observer reports the video id. Both ids are the same track, so the
    /// observation is mapped back to the song id. Without this the queue-drift handlers would read
    /// the switch as a wrong track and fight YouTube on every update, and the resolved artwork
    /// would become the video still instead of the song's album art.
    func canonicalPlaybackVideoId(for observedVideoId: String?) -> String? {
        guard let observedVideoId, !observedVideoId.isEmpty else { return observedVideoId }
        if observedVideoId == self.currentTrack?.videoId { return observedVideoId }

        if let videoVariantVideoId = self.currentTrackVideoVariant?.videoId,
           observedVideoId == videoVariantVideoId
        {
            return self.currentTrack?.videoId ?? observedVideoId
        }

        if let entry = self.queue[safe: self.currentIndex],
           observedVideoId == entry.counterpart?.videoId
        {
            return entry.videoId
        }

        // Sidebar-video variant learned earlier (see `foldUnknownObservationIfSidebarSwitch`):
        // fold it for this exact item only, so track ends and late updates on the
        // variant page keep working against the song entry.
        if let learned = self.observedVideoVariantVideoId,
           let scope = self.observedVideoVariantForVideoId,
           observedVideoId == learned,
           scope == (self.pendingPlayVideoId ?? self.currentTrack?.videoId)
        {
            return scope
        }

        return observedVideoId
    }

    /// Folds an unknown WebView observation onto the item that is playing while its video
    /// is showing.
    ///
    /// A sidebar-video switch can leave the page on an id Kaset does not track (an unpaired
    /// video variant, or a transient player id for a podcast) while the title still names the
    /// current item. Returning the item id keeps the drift handlers below from reloading the
    /// page out from under the showing video — that reload is what flashed the page and left
    /// a black surface. The title is the discriminant: a stale update or autoplay elsewhere
    /// carries another title. Ids that belong to the queue are never folded, so a genuine move
    /// is still caught.
    ///
    /// A song's variant is remembered for the rest of that song (the page stays on it, and
    /// late updates must keep folding). Podcasts have no variants, so theirs is not.
    func foldUnknownObservationIfSidebarSwitch(
        observedVideoId: String,
        title: String,
        artist: String
    ) -> String? {
        guard self.isSidebarVideoShowing,
              let itemId = self.pendingPlayVideoId ?? self.currentTrack?.videoId,
              observedVideoId != itemId,
              !self.queue.contains(where: { $0.videoId == observedVideoId })
        else { return nil }

        // A learned variant is the one unknown id that keeps folding; anything else is drift.
        if self.observedVideoVariantForVideoId == itemId {
            return self.observedVideoVariantVideoId == observedVideoId ? itemId : nil
        }
        guard self.observedMetadataMatchesCurrentItem(title: title, artist: artist) else { return nil }
        guard !self.isCurrentTrackPodcast else { return itemId }

        self.observedVideoVariantVideoId = observedVideoId
        self.observedVideoVariantForVideoId = itemId
        self.logger.info(
            "Learned video-variant \(observedVideoId) for item \(itemId) from sidebar-video switch"
        )
        return itemId
    }

    /// Whether an observation names the item that is playing: same title and artist, or a
    /// track still showing the "Loading..." placeholder (nothing to compare yet).
    private func observedMetadataMatchesCurrentItem(title: String, artist: String) -> Bool {
        let itemId = self.pendingPlayVideoId ?? self.currentTrack?.videoId
        let items = [self.queue.first(where: { $0.videoId == itemId }), self.currentTrack].compactMap { $0 }
        let isPlaceholder = items.contains {
            $0.title.isEmpty || $0.title == "Loading..." || $0.artists.isEmpty
        }
        return isPlaceholder
            || items.contains { self.metadataMatchesSong(title: title, artist: artist, song: $0) }
    }

    // MARK: - Artist Identity Matching

    /// Canonicalizes an artist string for **identity comparisons** so that YouTube's
    /// localized multi-artist separators compare equal to ours: "Artist A, Artist B",
    /// "Artist A and Artist B", "Artist A und Artist B", "Artist A et Artist B", and
    /// "Artist A & Artist B" all describe the same song.
    ///
    /// - Important: This is a *comparison* normalization — it folds diacritics and
    ///   lowercases, which is lossy. Never build user-visible text from its result;
    ///   use ``commaSeparatedArtistDisplay(_:)`` instead.
    static func canonicalArtistString(_ artist: String) -> String {
        Self.normalizingArtistSeparators(artist, forComparison: true)
    }

    /// Returns whether two artist display strings refer to the same set of artists,
    /// ignoring case, diacritics, and separator/conjunction formatting.
    static func artistsEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        Self.canonicalArtistString(lhs) == Self.canonicalArtistString(rhs)
    }

    /// Converts a localized YouTube byline into Kaset's stable comma-separated display format.
    ///
    /// The normalization only rewrites separators; it never case-folds, so the artist
    /// name is shown exactly as YouTube reports it ("ItsArius, Lynnic und Dinia" becomes
    /// "ItsArius, Lynnic, Dinia", not "itsarius, lynnic, dinia").
    static func commaSeparatedArtistDisplay(_ artist: String) -> String {
        let normalized = Self.normalizingArtistSeparators(artist, forComparison: false)
        guard !normalized.isEmpty else { return "" }
        return normalized
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: ", ")
    }

    /// Rewrites the separators YouTube uses between artists into plain commas.
    ///
    /// - Parameter forComparison: `true` additionally folds diacritics and lowercases the
    ///   result for identity matching. `false` keeps the original characters so the value
    ///   is safe to show to the user. Both variants apply the exact same separator rules so
    ///   the displayed string always canonicalizes back to the compared one.
    private static func normalizingArtistSeparators(_ artist: String, forComparison: Bool) -> String {
        var normalized = forComparison
            ? artist.folding(options: [.diacriticInsensitive], locale: .current).lowercased()
            : artist

        // Localized conjunctions used to join multiple artists become separators
        // ("and", German "und", French "et", Spanish "y", ampersand).
        normalized = normalized.replacingOccurrences(
            of: #"\b(?:and|und|et|y)\b"#,
            with: ",",
            options: [.regularExpression, .caseInsensitive]
        )
        normalized = normalized.replacingOccurrences(of: "&", with: ",")

        // Unify remaining punctuation separators (bullet, middot, semicolon, slash, pipe).
        normalized = normalized.replacingOccurrences(
            of: #"[•·;,/|]+"#,
            with: ",",
            options: .regularExpression
        )

        // Collapse whitespace and normalize comma spacing.
        normalized = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"\s*,\s*"#,
            with: ",",
            options: .regularExpression
        )

        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: ", "))
    }

    private func observedTrackMatchesSong(
        observedVideoId: String?,
        title: String,
        artist: String,
        song: Song
    ) -> Bool {
        if let observedVideoId = self.normalizedObservedVideoId(observedVideoId) {
            return song.videoId == observedVideoId
        }
        return song.title == title && Self.artistsEquivalent(song.artistsDisplay, artist)
    }

    private func metadataMatchesSong(title: String, artist: String, song: Song) -> Bool {
        song.title == title && Self.artistsEquivalent(song.artistsDisplay, artist)
    }

    private func shouldKeepQueueMetadata(title: String, artist: String, song: Song) -> Bool {
        title.isEmpty || artist.isEmpty || !self.metadataMatchesSong(title: title, artist: artist, song: song)
    }

    private var canAdvanceNativeQueueAfterTrackEnd: Bool {
        self.shuffleEnabled
            || self.repeatMode == .one
            || self.currentIndex < self.queue.count - 1
            || self.repeatMode == .all
            || self.mixContinuationToken != nil
    }

    private func expectedQueueIndexAfterCurrentTrack() -> Int? {
        guard !self.queue.isEmpty else { return nil }
        if self.repeatMode == .one {
            return self.currentIndex
        }
        guard !self.shuffleEnabled else { return nil }
        if self.currentIndex < self.queue.count - 1 {
            return self.currentIndex + 1
        }
        if self.repeatMode == .all {
            return 0
        }
        return nil
    }

    private func isRepeatAllWraparoundTrackEnd(
        observedVideoId: String,
        expectedCurrentVideoId: String
    ) -> Bool {
        guard self.repeatMode == .all,
              !self.shuffleEnabled,
              self.expectedQueueIndexAfterCurrentTrack() == 0,
              let currentQueueSong = self.queue[safe: self.currentIndex],
              let firstQueueSong = self.queue.first
        else {
            return false
        }

        // At the repeat-all boundary, YouTube can report the first queue song as the
        // observed id before the natural `ended` callback reaches Kaset.
        return currentQueueSong.videoId == expectedCurrentVideoId
            && firstQueueSong.videoId == observedVideoId
    }

    /// Keeps the queue song's metadata visible instead of YouTube's observed row.
    ///
    /// The observed `thumbnailUrl` comes from the player bar's `<img src>`, which is the *same*
    /// artwork served from a differently signed/sized URL and is rewritten by YouTube while it
    /// upgrades the image. Adopting it would churn `currentTrack`'s URL and make the now-playing
    /// artwork reload the picture it is already showing (visible flicker), so the queue song's own
    /// thumbnail wins whenever it has one.
    func keepQueueSongVisible(_ song: Song, thumbnailUrl: String) {
        self.logger.notice(
            "TRACE queue row shown: '\(song.title, privacy: .public)' (\(song.videoId, privacy: .public))"
        )
        let intendedThumbnailURL = song.thumbnailURL ?? self.normalizedThumbnailURL(thumbnailUrl)
        self.currentTrack = Song(
            id: song.id,
            title: song.title,
            artists: song.artists,
            album: song.album,
            duration: song.duration,
            thumbnailURL: intendedThumbnailURL,
            videoId: song.videoId,
            hasVideo: song.hasVideo,
            musicVideoType: song.musicVideoType,
            likeStatus: song.likeStatus,
            isInLibrary: song.isInLibrary,
            feedbackTokens: song.feedbackTokens
        )
    }

    private func makeObservedTrack(
        title: String,
        artist: String,
        thumbnailUrl: String,
        videoId: String
    ) -> Song {
        let thumbnailURL = self.resolvedThumbnailURL(observed: thumbnailUrl, videoId: videoId)
        let artistObj = Artist(id: "unknown", name: Self.commaSeparatedArtistDisplay(artist))
        return Song(
            id: videoId,
            title: title,
            artists: [artistObj],
            album: nil,
            duration: self.duration > 0 ? self.duration : nil,
            thumbnailURL: thumbnailURL,
            videoId: videoId
        )
    }

    private func isAtNativeQueueBoundaryForAutoplay() -> Bool {
        !self.queue.isEmpty && !self.canAdvanceNativeQueueAfterTrackEnd
    }

    private var isInsideNearEndTransitionWindow: Bool {
        guard self.duration > 0 else { return false }
        // Keep this window slightly wider than the playback-state marker so queue reconciliation
        // can run before WebView autoplay flashes a non-queue track.
        return self.progress >= max(0, self.duration - 4)
    }

    private func handleYouTubeAutoplayOutsideNativeQueue(
        observedVideoId: String,
        title: String,
        artist: String,
        thumbnailUrl: String,
        trackChanged: Bool,
        fromNearEndTransition: Bool = false
    ) -> Bool {
        guard self.isAtNativeQueueBoundaryForAutoplay(),
              fromNearEndTransition || self.state == .ended || self.isAwaitingYouTubeAutoplayAfterQueueEnd
        else {
            return false
        }

        if trackChanged {
            self.resetTrackStatus()
        }

        self.activateYouTubeAutoplay(videoId: observedVideoId)
        self.pendingPlayVideoId = observedVideoId
        self.currentTrack = self.makeObservedTrack(
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            videoId: observedVideoId
        )
        self.logger.info("YouTube autoplay started outside native queue with \(observedVideoId)")
        Task {
            await self.syncYouTubeAutoplayQueueIfPossible(
                observedVideoId: observedVideoId,
                title: title,
                artist: artist,
                thumbnailUrl: thumbnailUrl
            )
        }
        return true
    }

    private func syncYouTubeAutoplayQueueIfPossible(
        observedVideoId: String,
        title: String,
        artist: String,
        thumbnailUrl: String
    ) async {
        guard self.isYouTubeAutoplayActive,
              self.youTubeAutoplaySeedVideoId == observedVideoId,
              !self.isFetchingYouTubeAutoplayQueue
        else {
            return
        }

        self.isFetchingYouTubeAutoplayQueue = true
        defer {
            self.isFetchingYouTubeAutoplayQueue = false
        }

        guard self.isYouTubeAutoplayActive,
              self.youTubeAutoplaySeedVideoId == observedVideoId
        else {
            return
        }

        guard let client = self.ytMusicClient else {
            return
        }

        do {
            let seededQueue = try await client.getRadioQueue(videoId: observedVideoId).songs

            guard self.isYouTubeAutoplayActive,
                  self.youTubeAutoplaySeedVideoId == observedVideoId
            else {
                return
            }

            let autoplaySong = self.makeObservedTrack(
                title: title,
                artist: artist,
                thumbnailUrl: thumbnailUrl,
                videoId: observedVideoId
            )

            var syncedQueue = seededQueue
            if syncedQueue.isEmpty {
                syncedQueue = [autoplaySong]
            } else if !syncedQueue.contains(where: { $0.videoId == observedVideoId }) {
                syncedQueue.insert(autoplaySong, at: 0)
            }

            // Prefer the song version of the autoplay seed too, and keep the index on it.
            let preferredVideoId = self.audioPreferredVariant(autoplaySong).videoId
            let preparedQueue = self.normalizedVariants(syncedQueue)
            let preparedIndex = preparedQueue.firstIndex(where: { $0.videoId == preferredVideoId }) ?? 0

            self.clearForwardSkipNavigationStack()
            self.queue = preparedQueue
            self.currentIndex = preparedIndex
            self.currentTrack = preparedQueue[safe: preparedIndex] ?? autoplaySong
            self.pendingPlayVideoId = self.currentTrack?.videoId ?? observedVideoId
            self.mixContinuationToken = nil
            // YouTube's own autoplay replaced the queue, so any automix tuning row no longer applies.
            self.setQueueTunerChips([])
            self.saveQueueForPersistence()
            self.deactivateYouTubeAutoplayOutsideQueueState()
            self.logger.info("Synced seed-based autoplay queue with \(self.queue.count) songs")
        } catch {
            self.logger.warning("Failed to sync seed-based autoplay queue: \(error.localizedDescription)")
        }
    }

    private func suppressUnexpectedAutoplayAfterQueueEndIfNeeded(
        trackChanged: Bool,
        observedVideoId: String?,
        title: String,
        artist: String,
        thumbnailUrl: String
    ) -> Bool {
        guard trackChanged,
              self.shouldSuppressAutoplayAfterQueueEnd,
              let currentQueueSong = self.queue[safe: self.currentIndex],
              !self.observedTrackMatchesSong(
                  observedVideoId: observedVideoId,
                  title: title,
                  artist: artist,
                  song: currentQueueSong
              )
        else {
            return false
        }

        self.markPlaybackEnded()
        self.logger.info("Suppressing unexpected autoplay after native queue ended")
        self.keepQueueSongVisible(currentQueueSong, thumbnailUrl: thumbnailUrl)
        Task {
            await self.pause()
        }
        return true
    }

    private func handleKasetInitiatedPlaybackMetadata(
        observedVideoId: String?,
        title: String,
        artist: String,
        thumbnailUrl: String,
        trackChanged: Bool,
        barDescribesAnotherTrack: Bool
    ) -> Bool {
        guard self.isKasetInitiatedPlayback, !self.queue.isEmpty else {
            return false
        }

        guard let intendedSong = self.queue[safe: self.currentIndex] else {
            self.isKasetInitiatedPlayback = false
            return false
        }

        let matchesObservedVideo = self.normalizedObservedVideoId(observedVideoId) == intendedSong.videoId
        if matchesObservedVideo {
            self.isKasetInitiatedPlayback = false
            let displayArtist = Self.commaSeparatedArtistDisplay(artist)

            // Half a bar (still rendering, an empty byline) says nothing; the queue's row stays. A
            // complete one is how the track is really spelled, and a row built from a card can be
            // wrong about that — so the page's text replaces it, on the row's richer fields.
            guard !title.isEmpty, !displayArtist.isEmpty else {
                self.logger.debug(
                    "Confirmed intended videoId \(intendedSong.videoId) with incomplete metadata '\(title)'; keeping queue metadata"
                )
                self.keepQueueSongVisible(intendedSong, thumbnailUrl: thumbnailUrl)
                return true
            }

            if self.metadataMatchesSong(title: title, artist: displayArtist, song: intendedSong)
                || barDescribesAnotherTrack
            {
                self.keepQueueSongVisible(intendedSong, thumbnailUrl: thumbnailUrl)
            } else {
                self.logger.info(
                    "The page spells \(intendedSong.videoId) as '\(title)' - '\(displayArtist)'; correcting the row's text"
                )
                self.currentTrack = self.heldTrack(
                    intendedSong,
                    describedAs: title,
                    by: displayArtist,
                    thumbnailUrl: thumbnailUrl
                )
            }
            return true
        }

        if self.observedTrackMatchesSong(
            observedVideoId: observedVideoId,
            title: title,
            artist: artist,
            song: intendedSong
        ) {
            self.isKasetInitiatedPlayback = false
            self.logger.debug("Confirmed Kaset-initiated playback for '\(intendedSong.title)'")
            return false
        }

        guard trackChanged else {
            return false
        }

        let resolvedVideoId = self.resolvedObservedVideoId(observedVideoId)
        self.logger.info(
            "YouTube loaded different track '\(title)' (\(resolvedVideoId)), re-playing intended track '\(intendedSong.title)'"
        )
        self.isKasetInitiatedPlayback = false
        Task {
            await self.play(song: intendedSong, webLoadStrategy: .forceFullPageWhenSameVideoId)
        }
        return true
    }

    private func handleNearEndTrackChangeIfNeeded(
        observedVideoId: String?,
        title: String,
        artist: String,
        thumbnailUrl: String,
        trackChanged: Bool
    ) -> Bool {
        guard trackChanged,
              !self.queue.isEmpty,
              self.songNearingEnd || self.isInsideNearEndTransitionWindow
        else {
            return false
        }

        self.songNearingEnd = false

        // An observation of the row Kaset is already on is not a transition to another track: the page
        // agrees with the queue. Advancing from here skipped the row after the one that had just
        // started, which is what a natural track end looked like — the finished song's progress is
        // still on screen when the next track is first reported, so this handler believed a track had
        // changed near the end and pushed the queue one row further.
        if self.observedVideoIsCurrentQueueRow(observedVideoId: observedVideoId) {
            self.logger.debug("Near-end: observation is the row already playing; not a transition")
            return false
        }

        if let expectedNextIndex = self.expectedQueueIndexAfterCurrentTrack(),
           let expectedNextTrack = self.queue[safe: expectedNextIndex]
        {
            if !self.observedTrackMatchesSong(
                observedVideoId: observedVideoId,
                title: title,
                artist: artist,
                song: expectedNextTrack
            ) {
                // Repeat one: "expected next" is still the current row — do not call `next()` (that advances the queue).
                if self.repeatMode == .one {
                    self.logger.info(
                        "YouTube autoplay near end during repeat one; re-asserting current queue track (not advancing)"
                    )
                    Task {
                        await self.replayCurrentQueueSongForRepeatOneAfterTrackEnd()
                    }
                    return true
                }
                // The same transition can be observed more than once (the page reports several times
                // as it moves on). Advancing on each sighting skipped the row after the expected one.
                if self.pendingPlayVideoId == expectedNextTrack.videoId,
                   self.currentIndex == expectedNextIndex
                {
                    self.logger.debug(
                        "Near-end: already advancing to \(expectedNextTrack.videoId); not advancing again"
                    )
                    return true
                }

                self.logger.info("YouTube autoplay detected, overriding with queue track")
                self.advanceForNearEndTransition()
                return true
            }

            self.currentIndex = expectedNextIndex
            self.pendingPlayVideoId = expectedNextTrack.videoId
            self.logger.info("Track advanced to queue index \(expectedNextIndex)")
            self.saveQueueForPersistence()

            if self.shouldKeepQueueMetadata(title: title, artist: artist, song: expectedNextTrack) {
                self.logger.debug(
                    "Observed queue track \(expectedNextTrack.videoId) with incomplete metadata; keeping queue metadata"
                )
                self.keepQueueSongVisible(expectedNextTrack, thumbnailUrl: thumbnailUrl)
                return true
            }
            return false
        }

        if self.canAdvanceNativeQueueAfterTrackEnd {
            if self.repeatMode == .one {
                self.logger.info("Near-end track change with repeat one; re-asserting current queue track")
                Task {
                    await self.replayCurrentQueueSongForRepeatOneAfterTrackEnd()
                }
                return true
            }
            self.logger.info("Near-end track change detected, advancing native queue to enforce playback order")
            self.advanceForNearEndTransition()
            return true
        }

        guard let observedVideoId = self.normalizedObservedVideoId(observedVideoId) else {
            self.markPlaybackEnded()
            return true
        }

        return self.handleYouTubeAutoplayOutsideNativeQueue(
            observedVideoId: observedVideoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            trackChanged: trackChanged,
            fromNearEndTransition: true
        )
    }

    /// Treats a report of another track right after a start as the page's leftover advance.
    ///
    /// YouTube Music completes its own advance *after* it reports the previous track's end, so a track
    /// started in that gap plays for a moment and is then moved past — the song that was skipped one
    /// row too far. A row that started within ``PlayerService/trackStartGrace`` cannot have been skipped
    /// by the user, so the row is put back into the page instead of following it.
    ///
    /// - Returns: `true` when the report was one of those and has been handled.
    @discardableResult
    func handleTrackSkippedRightAfterStart(
        observedVideoId: String?,
        trackChanged: Bool
    ) -> Bool {
        guard trackChanged,
              self.isWithinTrackStartGrace,
              let row = self.queue[safe: self.currentIndex],
              let observed = self.normalizedObservedVideoId(observedVideoId),
              observed != row.videoId
        else {
            return false
        }

        self.logger.info(
            "The page moved to \(observed) right after \(row.videoId) started; putting the row back"
        )
        // That track's title and artwork are not the playing song's (lyrics read this).
        self.observedWebMetadata = nil
        self.reassertCurrentRowInPage()
        return true
    }

    /// Whether the observation names the queue row Kaset is already on.
    ///
    /// The video id decides this, not the text: titles and bylines drift constantly (remaster labels,
    /// joined credits, a bar that lags a beat), and reading that drift as a track change near the end
    /// of a song pushed the queue past the track that had just started — the remembered "it skipped a
    /// song by itself" bug.
    private func observedVideoIsCurrentQueueRow(observedVideoId: String?) -> Bool {
        guard let observedVideoId = self.normalizedObservedVideoId(observedVideoId) else {
            return false
        }
        let currentVideoId = self.queue[safe: self.currentIndex]?.videoId ?? self.currentTrack?.videoId
        return currentVideoId == observedVideoId
    }

    /// Advances the queue for a near-end track change, at most once per transition.
    ///
    /// Near the end of a song the WebView reports several times as the page moves on, and every report
    /// of the same unexpected track used to advance the queue again — which is heard as a song being
    /// skipped while the bar still shows the track Kaset had just started.
    func advanceForNearEndTransition() {
        let now = ContinuousClock.now
        if let last = self.lastNearEndAdvanceInstant, now - last < .milliseconds(1500) {
            self.logger.debug("Near-end: an advance is already in flight; not advancing again")
            return
        }
        self.lastNearEndAdvanceInstant = now
        Task {
            await self.advanceQueueForObservedTrackEnd()
        }
    }

    /// Advances the queue once for a track that ended, whichever signal noticed it first.
    ///
    /// The page's `ended` event and a metadata observation near the end of a song both report the same
    /// end. `next()` moves the index before it awaits, so two calls that overlap skip a row — which is
    /// heard as the song after the next one starting.
    func advanceQueueForObservedTrackEnd() async {
        guard !self.isAutomaticQueueAdvanceInFlight else {
            self.logger.debug("A track end is already advancing the queue; not advancing again")
            return
        }
        self.isAutomaticQueueAdvanceInFlight = true
        self.noteTrackEndedAdvance()
        defer { self.isAutomaticQueueAdvanceInFlight = false }
        await self.next()
    }

    /// Last-line repeat-one enforcement: WebView metadata is lossy/out-of-order; earlier handlers can miss a frame.
    /// This does **not** guarantee recovery if the bridge stops firing — only consolidates what we can observe here.
    private func finalRepeatOneSafetyNetIfNeeded(
        observedVideoId: String?,
        title: String,
        artist: String,
        thumbnailUrl: String,
        trackChanged: Bool
    ) -> Bool {
        guard self.repeatMode == .one,
              self.hasUserInteractedThisSession,
              let queued = self.queue[safe: self.currentIndex]
        else {
            return false
        }

        let observedNorm = self.normalizedObservedVideoId(observedVideoId)
        let videoMismatch = observedNorm.map { $0 != queued.videoId } ?? false
        let titleDriftWithoutVideoId =
            observedNorm == nil
                && !title.isEmpty
                && trackChanged
                && !self.metadataMatchesSong(title: title, artist: artist, song: queued)

        guard videoMismatch || titleDriftWithoutVideoId else {
            return false
        }

        self.keepQueueSongVisible(queued, thumbnailUrl: thumbnailUrl)

        let now = ContinuousClock.now
        if let last = self.lastRepeatOneRecoveryInstant,
           now - last < .milliseconds(450)
        {
            self.logger.debug("Repeat one: safety net throttled (bursty metadata)")
            return true
        }
        self.lastRepeatOneRecoveryInstant = now

        self.logger.info("Repeat one: safety net re-asserting queue track (observed=\(observedNorm ?? "nil"))")
        Task {
            await self.play(song: queued, webLoadStrategy: .forceFullPageWhenSameVideoId)
        }
        return true
    }

    private func handleUnexpectedQueueDriftIfNeeded(
        observedVideoId: String?,
        title: String,
        artist: String,
        thumbnailUrl: String,
        trackChanged: Bool
    ) -> Bool {
        guard !self.queue.isEmpty,
              let observedVideoId = self.normalizedObservedVideoId(observedVideoId),
              let currentQueueSong = self.queue[safe: self.currentIndex],
              currentQueueSong.videoId != observedVideoId
        else {
            return false
        }

        // Repeat one: autoplay can swap the video before title/artist update, so `trackChanged` may still be false.
        // Without this branch we fall through and assign `currentTrack` from YouTube, breaking UI sync.
        guard trackChanged || self.repeatMode == .one else {
            return false
        }

        // Repeat one: never realign `currentIndex` to another queue item when YouTube briefly loads
        // a different in-queue video (autoplay); that would break repeat and jump the queue pointer.
        if self.repeatMode == .one {
            self.logger.info(
                "Repeat one: observed \(observedVideoId) diverged from queue; re-playing without advancing queue index"
            )
            Task {
                await self.play(song: currentQueueSong, webLoadStrategy: .forceFullPageWhenSameVideoId)
            }
            return true
        }

        if let matchingIndex = self.queue.firstIndex(where: { $0.videoId == observedVideoId }),
           let matchingSong = self.queue[safe: matchingIndex]
        {
            if !self.isYouTubeAutoplayIndicatorVisible {
                self.clearYouTubeAutoplayState()
            }
            let queueIndexChanged = matchingIndex != self.currentIndex
            if queueIndexChanged {
                self.currentIndex = matchingIndex
                self.pendingPlayVideoId = matchingSong.videoId
                self.logger.info("Observed playback moved to queue index \(matchingIndex), realigning native queue")
                self.saveQueueForPersistence()
            }

            if queueIndexChanged || self.shouldKeepQueueMetadata(title: title, artist: artist, song: matchingSong) {
                if self.currentTrack?.videoId != matchingSong.videoId {
                    self.resetTrackStatus()
                    // Immediately restore like status from SongLikeStatusManager cache
                    if let cachedStatus = SongLikeStatusManager.shared.status(for: matchingSong.videoId) {
                        self.currentTrackLikeStatus = cachedStatus
                    }
                }
                self.keepQueueSongVisible(matchingSong, thumbnailUrl: thumbnailUrl)
                return true
            }
            return false
        }

        if self.isYouTubeAutoplayIndicatorVisible,
           self.repeatMode == .off,
           !self.shuffleEnabled,
           !self.queue.isEmpty
        {
            let autoplaySong = self.makeObservedTrack(
                title: title,
                artist: artist,
                thumbnailUrl: thumbnailUrl,
                videoId: observedVideoId
            )
            if trackChanged {
                self.resetTrackStatus()
            }
            self.currentTrack = autoplaySong
            self.queue.append(autoplaySong)
            self.currentIndex = self.queue.count - 1
            self.saveQueueForPersistence()
            self.logger.info("Mirrored next YouTube autoplay track into queue at index \(self.currentIndex)")
            return true
        }

        if self.handleYouTubeAutoplayOutsideNativeQueue(
            observedVideoId: observedVideoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            trackChanged: trackChanged
        ) {
            return true
        }

        self.logger.info(
            "Observed track \(observedVideoId) diverged from native queue track \(currentQueueSong.videoId); re-playing intended queue track"
        )
        Task {
            await self.play(song: currentQueueSong, webLoadStrategy: .forceFullPageWhenSameVideoId)
        }
        return true
    }

    /// Replays the current queue song after a natural `ended` event. User-initiated **Next** uses ``PlayerService/next()`` instead.
    private func replayCurrentQueueSongForRepeatOneAfterTrackEnd() async {
        guard let currentSong = self.queue[safe: self.currentIndex] else { return }
        self.songNearingEnd = false
        let kasetAlignedWithQueue = self.pendingPlayVideoId == currentSong.videoId
            && SingletonPlayerWebView.shared.currentVideoId == currentSong.videoId
        if self.hasUserInteractedThisSession, kasetAlignedWithQueue {
            SingletonPlayerWebView.shared.restartInPlaceFromBeginning()
            if self.state == .ended || self.state == .loading {
                self.state = .playing
            }
        } else {
            await self.play(song: currentSong, webLoadStrategy: .preferInPlaceWhenSameVideoId)
        }
    }

    /// Replays the currently playing song for repeat-one when no native queue is active.
    private func replayCurrentSongForRepeatOneWithoutQueueAfterTrackEnd() async {
        self.songNearingEnd = false
        self.noteTrackEndedAdvance()
        if let currentTrack = self.currentTrack {
            self.logger.info("Track ended with repeat one and no queue; replaying current track")
            await self.play(song: currentTrack, webLoadStrategy: .preferInPlaceWhenSameVideoId)
            return
        }

        if let pendingVideoId = self.pendingPlayVideoId {
            self.logger.info("Track ended with repeat one and no queue metadata; replaying pending video")
            await self.play(videoId: pendingVideoId)
            return
        }
    }

    /// Handles a natural track completion reported directly by the WebView.
    ///
    /// - Parameter progress: where the media stopped, when the page reports it.
    /// - Parameter duration: the media's own length, when the page reports it. Together they are the
    ///   proof that the track reached its end: a report from a load that kept the old position (or from
    ///   media the page replaced) is not this track finishing, and advancing on it skipped a queue row.
    func handleTrackEnded(
        observedVideoId: String?,
        progress: TimeInterval? = nil,
        duration: TimeInterval? = nil
    ) async {
        self.logger.debug("Track ended reported by WebView: \(observedVideoId ?? "unknown")")

        if let progress, let duration, duration > 0, progress < duration - 3 {
            self.logger.info(
                "Ignoring track-ended for \(observedVideoId ?? "unknown"): it stopped at \(Int(progress))s of \(Int(duration))s"
            )
            return
        }

        // A video-variant page ends the same track; fold it onto the song id so the queue
        // advances (or repeats) correctly rather than discarding the event as stale.
        let observedVideoId = self.canonicalPlaybackVideoId(for: observedVideoId)
        self.songNearingEnd = false

        // A track that started moments ago has not finished: this is the page's leftover advance from
        // the previous song ending (or from a swap made while it was still finishing), and advancing
        // here skipped a queue row. The row is put back instead.
        if self.isWithinTrackStartGrace,
           self.normalizedObservedVideoId(observedVideoId) == self.queue[safe: self.currentIndex]?.videoId
        {
            self.logger.info(
                "Ignoring track-ended for \(observedVideoId ?? "unknown"): it started moments ago; putting the row back"
            )
            self.reassertCurrentRowInPage()
            return
        }

        guard !self.queue.isEmpty else {
            if self.repeatMode == .one, self.currentTrack != nil || self.pendingPlayVideoId != nil {
                await self.replayCurrentSongForRepeatOneWithoutQueueAfterTrackEnd()
                return
            }
            self.markPlaybackEnded()
            return
        }
        if let observedVideoId = self.normalizedObservedVideoId(observedVideoId) {
            let currentQueueVideoId = self.queue[safe: self.currentIndex]?.videoId
            let expectedCurrentVideoId = currentQueueVideoId ?? self.currentTrack?.videoId ?? self.pendingPlayVideoId
            if let expectedCurrentVideoId, expectedCurrentVideoId != observedVideoId {
                // Late duplicate `ended` events should not advance the queue twice. The only mismatch
                // we allow is repeat-all wrapping from the last queue item back to the first song.
                if self.repeatMode == .one {
                    self.logger.info(
                        "Track ended: observed \(observedVideoId) != queue \(expectedCurrentVideoId) while repeat one is active; replaying current queue song"
                    )
                } else if self.isRepeatAllWraparoundTrackEnd(
                    observedVideoId: observedVideoId,
                    expectedCurrentVideoId: expectedCurrentVideoId
                ) {
                    self.logger.info(
                        "Track ended: observed \(observedVideoId) already wrapped from queue \(expectedCurrentVideoId); applying repeat-all wraparound"
                    )
                } else {
                    self.logger.debug(
                        "Ignoring stale track-ended event for \(observedVideoId); current queue track is \(expectedCurrentVideoId)"
                    )
                    return
                }
            }
        }

        guard self.canAdvanceNativeQueueAfterTrackEnd else {
            self.shouldSuppressAutoplayAfterQueueEnd = false
            self.isAwaitingYouTubeAutoplayAfterQueueEnd = true
            self.markPlaybackEnded()
            self.logger.info("Reached end of native queue; allowing YouTube autoplay handoff")
            return
        }
        self.shouldSuppressAutoplayAfterQueueEnd = false
        self.isAwaitingYouTubeAutoplayAfterQueueEnd = false
        if self.repeatMode == .one {
            self.noteTrackEndedAdvance()
            self.logger.info("Track ended with repeat one; replaying current queue song")
            await self.replayCurrentQueueSongForRepeatOneAfterTrackEnd()
            return
        }
        self.logger.info("Track ended in WebView, advancing native queue immediately")
        await self.advanceQueueForObservedTrackEnd()
    }

    /// Updates track metadata and enforces Kaset's queue when YouTube tries to diverge.
    func updateTrackMetadata(
        title: String,
        artist: String,
        thumbnailUrl: String,
        videoId observedVideoId: String?
    ) {
        self.updateTrackMetadata(
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            videoId: observedVideoId,
            playerBarVideoId: nil
        )
    }

    /// Updates track metadata and enforces Kaset's queue when YouTube tries to diverge.
    ///
    /// - Parameter playerBarVideoId: the track the player bar itself is describing, when the page says.
    ///   It lags an in-page track swap, so a bar naming another track is not a description of the
    ///   track that is playing.
    /// - Parameter metadataFromPlayer: whether the title and byline came from the page's *player API*
    ///   rather than its bar. The player's own words describe the video it holds, so a bar that still
    ///   names the previous track is no reason to doubt them — and the lyrics search waits on exactly
    ///   this observation.
    func updateTrackMetadata(
        title: String,
        artist: String,
        thumbnailUrl: String,
        videoId observedVideoId: String?,
        playerBarVideoId: String?,
        metadataFromPlayer: Bool = false
    ) {
        self.logger.debug(
            "TRACE observation id=\(observedVideoId ?? "-", privacy: .public) title='\(title, privacy: .public)' artist='\(artist, privacy: .public)' bar=\(playerBarVideoId ?? "-", privacy: .public) fromPlayer=\(metadataFromPlayer, privacy: .public) current=\(self.currentTrack?.videoId ?? "-", privacy: .public)"
        )

        if self.isAdPlaying {
            self.logger.debug("Ignoring metadata reconciliation while ad is active")
            return
        }

        // A page that was just told to play another track goes on reporting the one it is leaving for
        // a moment — a poll that raced the swap, an update queued before it, the bar's last paint.
        // That report is not the page moving back: believing it realigned the queue index to the row
        // that had just been left and flashed its title in the now-playing surfaces, until the next
        // report moved everything forward again. The row Kaset started is the one that is playing.
        if self.isObservationOfDepartedTrack(self.normalizedObservedVideoId(observedVideoId), title: title) {
            self.logger.notice(
                "TRACE ignored departed-track report id=\(observedVideoId ?? "-", privacy: .public) title='\(title, privacy: .public)'"
            )
            return
        }

        // The player bar can still be describing the previous track while the player has already
        // started the new one (an in-page swap does not reload the page). Believing that text would
        // store another song's title, artist and artwork for the playing track — the lyrics and the
        // byline would be the previous song's until something else corrected them. The bar's *text* is
        // therefore not taken, but the track the player holds still is: reconciliation has to run on it,
        // or the app would keep showing the previous row while the page plays the next one.
        let barDescribesAnotherTrack: Bool = {
            guard !metadataFromPlayer else { return false }
            guard let playerBarVideoId, !playerBarVideoId.isEmpty,
                  let observed = self.normalizedObservedVideoId(observedVideoId)
            else { return false }
            return self.canonicalPlaybackVideoId(for: playerBarVideoId) != observed
        }()
        if barDescribesAnotherTrack {
            self.logger.debug(
                "Player bar still shows \(playerBarVideoId ?? "nothing") while the player holds \(observedVideoId ?? "unknown"); keeping the queue's text"
            )
        }

        // The PiP miniplayer can put the page on the video variant; fold that observation back
        // onto the song entry so the queue stays authoritative and the album art is kept.
        let rawObservedVideoId = self.normalizedObservedVideoId(observedVideoId)
        var observedVideoId = self.canonicalPlaybackVideoId(for: observedVideoId)
        // Still unknown: it may be the sidebar-video switch to an id Kaset does not track.
        // Folding it here (with the title available as the discriminant) keeps the divergence
        // handlers below from reloading the page out from under the showing video.
        if observedVideoId == rawObservedVideoId, let raw = rawObservedVideoId {
            observedVideoId = self.foldUnknownObservationIfSidebarSwitch(
                observedVideoId: raw,
                title: title,
                artist: artist
            ) ?? observedVideoId
        }

        let displayArtist = Self.commaSeparatedArtistDisplay(artist)
        let artistObj = Artist(id: "unknown", name: displayArtist)
        let resolvedVideoId = self.resolvedObservedVideoId(observedVideoId)

        // Record the metadata the WebView just observed for this track, with the artist
        // separators normalized. The lyrics pipeline waits for this and searches with it,
        // so it never runs against the "Loading..." placeholder or a queue entry with a
        // title/artist YouTube has since refined. Set before the divergence handlers
        // below, since any of them can reconcile or early-return; only a complete
        // observation counts, so a half-rendered player bar cannot satisfy the gate.
        // Right after a start the page can still paint another song's words under the new video's id:
        // a measured case reported the correct id with a two-tracks-old title 0.2 s after the advance
        // and did not paint the real words until 1.4 s later. Text is therefore believed only when
        // something anchors it to the playing video — the player API's own record, or a bar whose link
        // names that video — and until then the row Kaset started keeps its words (and the lyrics gate
        // stays closed). A bar naming another track is left to its own handling below.
        if self.ignoresUnanchoredText(
            title: title,
            artist: displayArtist,
            videoId: resolvedVideoId,
            playerBarVideoId: playerBarVideoId,
            metadataFromPlayer: metadataFromPlayer
        ) {
            self.logger.notice(
                "TRACE ignored unanchored text for \(resolvedVideoId, privacy: .public): '\(title, privacy: .public)' - '\(displayArtist, privacy: .public)' (row says '\(self.currentTrack?.title ?? "-", privacy: .public)', bar=\(playerBarVideoId ?? "-", privacy: .public), fromPlayer=\(metadataFromPlayer, privacy: .public))"
            )
            // The page did name the video it holds; only its words are untrusted. The start is
            // therefore confirmed, and a later report is not read as an intended-track mismatch.
            if self.pendingPlayVideoId == resolvedVideoId {
                self.isKasetInitiatedPlayback = false
            }
            return
        }

        if !barDescribesAnotherTrack, !title.isEmpty, !displayArtist.isEmpty {
            self.observedWebMetadata = ObservedWebMetadata(
                videoId: resolvedVideoId,
                title: title,
                artist: displayArtist
            )
        }

        if let queuedSong = self.queue.first(where: { $0.videoId == resolvedVideoId }) {
            self.updateCurrentPlaybackKind(using: queuedSong)
        } else if self.currentTrack?.videoId == resolvedVideoId {
            self.updateCurrentPlaybackKind(using: self.currentTrack)
        } else {
            self.updateCurrentPlaybackKind(using: nil)
        }

        let thumbnailURL = self.resolvedThumbnailURL(observed: thumbnailUrl, videoId: resolvedVideoId)
        let trackChanged = self.currentTrack?.title != title
            || !Self.artistsEquivalent(self.currentTrack?.artistsDisplay ?? "", artist)
            || self.currentTrack?.videoId != resolvedVideoId

        if self.suppressUnexpectedAutoplayAfterQueueEndIfNeeded(
            trackChanged: trackChanged,
            observedVideoId: observedVideoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl
        ) {
            return
        }

        // A row that started a moment ago cannot have been skipped by the user: a different track here
        // is the page finishing its own advance from the previous song, and following it skipped the
        // track that had just started.
        if self.handleTrackSkippedRightAfterStart(
            observedVideoId: observedVideoId,
            trackChanged: trackChanged
        ) {
            return
        }

        if self.handleKasetInitiatedPlaybackMetadata(
            observedVideoId: observedVideoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            trackChanged: trackChanged,
            barDescribesAnotherTrack: barDescribesAnotherTrack
        ) {
            return
        }

        if self.handleNearEndTrackChangeIfNeeded(
            observedVideoId: observedVideoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            trackChanged: trackChanged
        ) {
            return
        }

        if self.handleUnexpectedQueueDriftIfNeeded(
            observedVideoId: observedVideoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            trackChanged: trackChanged
        ) {
            return
        }

        if self.queue.contains(where: { $0.videoId == resolvedVideoId }) {
            if self.isYouTubeAutoplayActive {
                self.deactivateYouTubeAutoplayOutsideQueueState()
            }
        }

        if self.finalRepeatOneSafetyNetIfNeeded(
            observedVideoId: observedVideoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            trackChanged: trackChanged
        ) {
            return
        }

        // Repeat one: never replace the queue-driven `currentTrack` with YouTube's row (autoplay after idle/end).
        if self.repeatMode == .one, let queued = self.queue[safe: self.currentIndex] {
            self.keepQueueSongVisible(queued, thumbnailUrl: thumbnailUrl)
            return
        }

        // The bar is describing a track that is not playing: its title and artwork are not this
        // song's, so the queue's row stays on screen until the bar catches up.
        if barDescribesAnotherTrack, let current = self.currentTrack {
            self.keepQueueSongVisible(current, thumbnailUrl: thumbnailUrl)
            return
        }

        // YouTube localizes the multi-artist separator in the player-bar byline
        // ("Artist A und Artist B"), which would otherwise replace our structured
        // artists and drop like-status/library fields on the current track. When the
        // observed metadata is equivalent to the current track, keep the richer one.
        let observedMatchesCurrent = self.currentTrack.map {
            self.metadataMatchesSong(title: title, artist: artist, song: $0)
        } ?? false

        if observedMatchesCurrent, let current = self.currentTrack {
            self.keepQueueSongVisible(current, thumbnailUrl: thumbnailUrl)
        } else if let queued = self.queue.first(where: { $0.videoId == resolvedVideoId }) {
            // Keep the row's album, duration, artwork and like state; take the page's text.
            self.logger.notice(
                "TRACE adopted page text for \(resolvedVideoId, privacy: .public): '\(title, privacy: .public)' - '\(displayArtist, privacy: .public)'"
            )
            self.currentTrack = self.heldTrack(
                queued,
                describedAs: title,
                by: displayArtist,
                thumbnailUrl: thumbnailUrl
            )
        } else {
            self.currentTrack = Song(
                id: resolvedVideoId,
                title: title,
                artists: [artistObj],
                album: nil,
                duration: self.duration > 0 ? self.duration : nil,
                thumbnailURL: thumbnailURL,
                videoId: resolvedVideoId
            )
        }

        if trackChanged {
            self.resetTrackStatus()
            // Immediately restore like status from SongLikeStatusManager cache
            if let cachedStatus = SongLikeStatusManager.shared.status(for: resolvedVideoId) {
                self.currentTrackLikeStatus = cachedStatus
            }
        }
    }

    /// Reconciles what a *preloaded* page reports about the track it is holding.
    ///
    /// The preload loads the track Kaset is about to play — the pending queue song, or the song a
    /// restored session would resume — into the WebView early and holds it silent. Until the user asks
    /// for it, that page is not the app's authority on anything: its player was told it started when
    /// its autoplay was swallowed, so its position, duration and playing flag describe a performance
    /// that never happened, and its queue and end-of-track signals would drive `next()` and `play()`
    /// from a page that is deliberately quiet. None of that is taken here, and the page is kept out of
    /// ``updateTrackMetadata``'s divergence handlers for the same reason.
    ///
    /// What the page *is* good for is which song it is showing. The title, artist and artwork its
    /// player bar renders are the same observations a playing page makes, they are what the artist
    /// separator normalization, the lyrics gate (``observedWebMetadata``) and the artwork fallback have
    /// been waiting for, and taking them now is what leaves the first press of play landing on a song
    /// that is already fully described instead of one that fills itself in seconds later.
    ///
    /// Deliberately narrower than ``updateTrackMetadata``: the queue stays the authority on what is
    /// playing, on the order, and on everything that makes its row richer — the album, the duration,
    /// the like state. What it does take is the title and artist *as the player bar renders them*,
    /// because those are what a restored session has been showing wrong: a queue row saved from an
    /// earlier session can carry a byline that still has the album, year and view count in it, and until
    /// playback starts nothing corrected it — pressing play did, by replacing `currentTrack` with the
    /// page's own rendering (see the tail of ``updateTrackMetadata``). Doing that here is what makes the
    /// bar read the same before and after the first press.
    func reconcilePreloadedTrackMetadata(
        title: String,
        artist: String,
        thumbnailUrl: String,
        videoId observedVideoId: String?
    ) {
        guard !self.isAdPlaying else { return }

        let displayArtist = Self.commaSeparatedArtistDisplay(artist)
        let resolvedVideoId = self.resolvedObservedVideoId(observedVideoId)

        guard let preloaded = self.currentTrack, preloaded.videoId == resolvedVideoId else {
            self.logger.debug(
                "Ignoring preloaded metadata for \(resolvedVideoId): it is not the track being held"
            )
            return
        }

        // The lyrics pipeline waits for a *complete* observation, so only one that has both parts
        // counts — the same rule `updateTrackMetadata` applies. This is the whole point of looking at
        // a page that is not playing: it is the first time a restored session can know how YouTube
        // itself renders the track it is about to resume.
        if !title.isEmpty, !displayArtist.isEmpty {
            let observation = ObservedWebMetadata(
                videoId: resolvedVideoId,
                title: title,
                artist: displayArtist
            )
            // A page settling into place reports repeatedly, and the lyrics view retries on any change
            // to this value. Only a genuinely new description is worth a write — and worth a log.
            if observation != self.observedWebMetadata {
                self.observedWebMetadata = observation
                self.logger.info("Preloaded track metadata updated: \(title) - \(displayArtist)")
            }
        }

        self.updateCurrentPlaybackKind(
            using: self.queue.first { $0.videoId == resolvedVideoId } ?? preloaded
        )

        // An observation that does not describe the held track is not about the held track: a page that
        // is not playing does not get to change what the app considers current, and the queue keeps its
        // richer row. Only artwork is still worth taking in that case — see below.
        guard self.metadataMatchesSong(title: title, artist: artist, song: preloaded) else {
            // The page names a different song, or names this one differently. Both are worth believing
            // only if the page said *which video* it is describing and it is the one being held: the
            // fallback in ``resolvedObservedVideoId(observedVideoId:)`` fills in the held id when the
            // page reports none, and a page that has not said what it is showing (a shell, a page still
            // settling, an ad) must not be allowed to rename the track.
            guard self.normalizedObservedVideoId(observedVideoId) == preloaded.videoId, !title.isEmpty,
                  !displayArtist.isEmpty
            else {
                self.logger.debug(
                    "Preloaded page reports '\(title)' for \(resolvedVideoId); keeping the held track"
                )
                self.keepPreloadedArtworkIfMissing(preloaded, thumbnailUrl: thumbnailUrl)
                return
            }

            self.currentTrack = self.heldTrack(
                preloaded,
                describedAs: title,
                by: displayArtist,
                thumbnailUrl: thumbnailUrl
            )
            self.logger.info(
                "Preloaded page described the held track as '\(title)' - '\(displayArtist)'; adopting it"
            )
            return
        }

        self.keepPreloadedArtworkIfMissing(preloaded, thumbnailUrl: thumbnailUrl)
    }

    /// Takes the page's artwork for a held track that has none.
    ///
    /// `fetchSongMetadata` can lose its race against account initialization, and a page load may be the
    /// only thing that delivers the picture before the user presses play. `keepQueueSongVisible` is
    /// exactly the rule for taking it: it fills in the picture we do not have while the queue's
    /// structured artists, album and like status stay on screen. A page settling into place reports
    /// several times, so this deliberately writes nothing once the track already has its artwork.
    private func keepPreloadedArtworkIfMissing(_ song: Song, thumbnailUrl: String) {
        guard song.thumbnailURL == nil, self.normalizedThumbnailURL(thumbnailUrl) != nil else { return }
        self.keepQueueSongVisible(song, thumbnailUrl: thumbnailUrl)
    }

    /// Whether a page description of the just-started track is too unattached to it to be believed.
    ///
    /// A title is anchored when the player API is the one reporting it (that record is for the video
    /// the player holds), or when the player bar's own link names the playing video (the bar's text is
    /// then that video's rendering). Anything else in the first moments after a start is the page still
    /// painting its previous state — the wrong song's words under the right id.
    private func ignoresUnanchoredText(
        title: String,
        artist: String,
        videoId: String,
        playerBarVideoId: String?,
        metadataFromPlayer: Bool
    ) -> Bool {
        guard self.isWithinStartedTrackTextGrace(videoId),
              !title.isEmpty, !artist.isEmpty,
              let current = self.currentTrack, current.videoId == videoId,
              !current.title.isEmpty, !current.artistsDisplay.isEmpty,
              !self.metadataMatchesSong(title: title, artist: artist, song: current)
        else { return false }

        if metadataFromPlayer { return false }
        if let bar = playerBarVideoId, !bar.isEmpty,
           (self.canonicalPlaybackVideoId(for: bar) ?? bar) == videoId
        {
            return false
        }
        return true
    }

    /// The held track with the page's title and artist written over it and every other field left as the
    /// queue has it.
    ///
    /// This is the one place a silent page is allowed to change what the bar shows, and it is bounded to
    /// the two strings the player bar renders: the album, duration, like state, library membership and
    /// feedback tokens of the queue's row are carried across untouched, so nothing the queue knows about
    /// the song is lost to a page that is only being used for its byline.
    private func heldTrack(
        _ song: Song,
        describedAs title: String,
        by artistsDisplay: String,
        thumbnailUrl: String
    ) -> Song {
        Song(
            id: song.id,
            title: title,
            artists: [Artist(id: "unknown", name: artistsDisplay)],
            album: song.album,
            duration: song.duration,
            thumbnailURL: song.thumbnailURL ?? self.normalizedThumbnailURL(thumbnailUrl),
            videoId: song.videoId,
            hasVideo: song.hasVideo,
            musicVideoType: song.musicVideoType,
            likeStatus: song.likeStatus,
            isInLibrary: song.isInLibrary,
            feedbackTokens: song.feedbackTokens
        )
    }
}
