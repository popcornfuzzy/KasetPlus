import Foundation

// MARK: - PlayerService + Page Playback

/// Asks the page's own player to change track inside the open document, and checks that it did.
///
/// A track change used to be a page navigation; this is the same change without the document. What the
/// page is asked is deliberately narrow — start this one track — because YouTube Music's player bar,
/// its store and its queue all describe the page's own playback, and rewriting any of that behind its
/// back is what leaves the bar showing a song that is no longer playing. Kaset's queue stays Kaset's;
/// the page is a player Kaset drives one track at a time.
@MainActor
extension PlayerService {
    /// How long a track the page was asked to start in place may take before Kaset loads the page.
    static let inPagePlayTimeout: Duration = .seconds(3)
    /// How long the page gets to report the track it started before the settle check looks.
    static let pageSettleDelay: Duration = .milliseconds(900)
    /// How long a track started right after a natural end is protected from being skipped.
    ///
    /// YouTube Music finishes its own advance *after* it reports `ended` for the previous track, so the
    /// track Kaset starts in that gap can be overwritten by an advance already in flight: it plays for a
    /// second and the page moves on to the next one. Inside this window a second track is that leftover
    /// advance, never a queue move, and the row is put back.
    ///
    /// The window opens only for a start caused by a track ending. A start the user asked for (play,
    /// Next, a queue row) has no advance in flight, so a track change right after it is still followed.
    static let trackStartGrace: Duration = .milliseconds(2500)

    /// Marks that the queue is advancing because a track ended.
    func noteTrackEndedAdvance() {
        self.pendingStartGrace = .now
    }

    /// Opens the window described by ``trackStartGrace`` when the incoming start follows an end.
    ///
    /// A start the user asked for clears it, so a deliberate skip moments after a track started is still
    /// followed rather than put back.
    func applyPendingStartGrace() {
        let followsAnEnd = self.pendingStartGrace.map { ContinuousClock.now - $0 < .seconds(1.5) } ?? false
        self.pendingStartGrace = nil
        self.currentRowStartedAt = followsAnEnd ? .now : nil
    }

    /// Whether the current row started too recently to have been skipped on purpose.
    var isWithinTrackStartGrace: Bool {
        guard let startedAt = self.currentRowStartedAt else { return false }
        return ContinuousClock.now - startedAt < Self.trackStartGrace
    }

    /// How long a report of the track playback has just left is treated as a stale report.
    ///
    /// The page keeps reporting the outgoing track for a moment after it is told to play another one: a
    /// poll that raced the swap, an update queued before it, the bar's last paint. That is not the page
    /// moving anywhere, so it may not move the queue or the now-playing text.
    static let departedTrackWindow: Duration = .seconds(3)

    /// How long after a start the page's own unanchored description of the new track is not believed.
    ///
    /// YouTube Music paints the player bar from its previous state for a moment after a track change:
    /// a measured case reported the new video's id with another song's title 0.2 s after the start and
    /// did not paint the real one until 1.4 s later. The bar's text is only trusted when the bar's own
    /// link names the playing video; otherwise the player API is the anchor, and until it has the words
    /// the row Kaset started keeps its own.
    static let startedTrackTextGrace: Duration = .seconds(2.5)

    /// Remembers that Kaset started `videoId`, and that it left `previous` to do so.
    ///
    /// A start is the only moment a track becomes *left*: the track that was playing is still in the
    /// page for a beat afterwards, and its reports must not be believed over the row Kaset just started.
    /// Starting a track that was left moments ago (Previous, a queue row picked again) takes it off the
    /// list, because it is live again — otherwise its own reports would be ignored.
    ///
    /// The track's *text* is remembered as well as its id: a page mid-swap can pair the new video's id
    /// with the outgoing song's words, and those words are the only way to tell that report from a
    /// genuine correction of the row.
    func noteTrackStart(from previous: Song?, to videoId: String) {
        let now = ContinuousClock.now
        self.lastStartedTrack = (videoId: videoId, at: now)
        self.departedTracks.removeAll { now - $0.at >= Self.departedTrackWindow }
        self.departedTracks.removeAll { $0.videoId == videoId }
        guard let previous, previous.videoId != videoId else { return }
        var titles = Set([Self.foldedMetadataText(previous.title)].filter { !$0.isEmpty })
        if let observed = self.observedWebMetadata, observed.videoId == previous.videoId, !observed.title.isEmpty {
            titles.insert(Self.foldedMetadataText(observed.title))
        }
        self.departedTracks.append((videoId: previous.videoId, titles: titles, at: now))
    }

    /// Whether `videoId` was started recently enough that the page may still be painting its predecessor.
    func isWithinStartedTrackTextGrace(_ videoId: String) -> Bool {
        guard let started = self.lastStartedTrack, started.videoId == videoId else { return false }
        return ContinuousClock.now - started.at < Self.startedTrackTextGrace
    }

    /// Whether an observation describes a track playback has left within ``departedTrackWindow``.
    ///
    /// The id and the words are both checked. The id catches a report of the outgoing video; the words
    /// catch the page pairing the new video's id with the outgoing song's title, which is what flashed
    /// that title in the now-playing column right after a skip.
    func isObservationOfDepartedTrack(_ observedVideoId: String?, title: String = "") -> Bool {
        let now = ContinuousClock.now
        let recent = self.departedTracks.filter { now - $0.at < Self.departedTrackWindow }
        guard !recent.isEmpty else { return false }

        if let observedVideoId, !observedVideoId.isEmpty {
            let canonical = self.canonicalPlaybackVideoId(for: observedVideoId) ?? observedVideoId
            if recent.contains(where: { $0.videoId == canonical }) { return true }
        }

        let folded = Self.foldedMetadataText(title)
        guard !folded.isEmpty else { return false }
        // The playing track's own words are never stale, even when another row shares its title (a
        // live/studio pair, a replay): this only decides about text the page reports *for this start*.
        if let current = self.currentTrack, Self.foldedMetadataText(current.title) == folded { return false }
        return recent.contains { $0.titles.contains(folded) }
    }

    /// Case- and diacritic-insensitive form of a reported title, for telling one song's words from another's.
    static func foldedMetadataText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Puts the row Kaset is on back into the page after the page skipped it on its own.
    ///
    /// The page is the player, so this is the only way to undo its advance; a bar that merely returned
    /// to the row while another track played would be the bug it is trying to prevent.
    func reassertCurrentRowInPage() {
        guard let row = self.queue[safe: self.currentIndex] else { return }
        self.keepQueueSongVisible(row, thumbnailUrl: "")
        SingletonPlayerWebView.shared.playInPage(videoId: row.videoId) { [weak self] status in
            guard let self, self.pendingPlayVideoId == row.videoId else { return }
            self.updatePagePlaybackCapability(status)
            guard WebPagePlaybackStatus.succeeded(status) else {
                self.loadExpectedTrackPage(videoId: row.videoId)
                return
            }
            // The advance that took the track away is still the page's own business: check again
            // shortly after putting the row back, this time without a second in-place correction.
            self.beginPageSettleCheck(videoId: row.videoId, reassertionsLeft: 0)
        }
    }

    // MARK: - Capability

    /// Records what a bridge call proved about this document's player.
    func updatePagePlaybackCapability(_ status: String) {
        self.pagePlaybackCapability = WebPagePlaybackStatus.capability(of: status)
        self.logger.debug(
            "Page playback capability: \(String(describing: self.pagePlaybackCapability)) (from '\(status)')"
        )
    }

    /// Forgets everything learned about the previous document (a navigation replaces it).
    func resetPagePlaybackBridge() {
        self.cancelPagePlaybackWatchdogs()
        self.pageSettleVideoId = nil
        self.pageSettleReassertionsLeft = 0
        self.pagePlaybackCapability = .unknown
    }

    /// Cancels the watchdogs (playback moved on, so their premises no longer hold).
    func cancelPagePlaybackWatchdogs() {
        self.inPagePlayWatchdog?.cancel()
        self.inPagePlayWatchdog = nil
        self.pageSettleTask?.cancel()
        self.pageSettleTask = nil
    }

    // MARK: - Watchdog

    /// Watches a track the page was asked to start without a document load.
    ///
    /// The page answering `loaded-video` only means it accepted the command. A player that silently
    /// ignores it would leave Kaset on a loading bar forever, so the long way is taken if nothing has
    /// started by the time the page should have been playing.
    func noteInPagePlayAttempt(videoId: String) {
        self.inPagePlayWatchdog?.cancel()
        self.inPagePlayWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.inPagePlayTimeout)
            guard let self, !Task.isCancelled else { return }
            guard self.pendingPlayVideoId == videoId, self.state == .loading else { return }

            self.logger.info("The page did not start \(videoId) in place; loading its watch page")
            self.pagePlaybackCapability = .unknown
            SingletonPlayerWebView.shared.loadWatchPage(videoId: videoId)
        }
    }

    // MARK: - Settle check

    /// Starts checking that the page is playing the track Kaset just asked for.
    ///
    /// One check, shortly after the start: the page's own end-of-track advance can move its player off
    /// the track Kaset started, and nothing else would notice — a metadata observation of the wrong
    /// song is treated as drift, not as a failed command.
    func beginPageSettleCheck(videoId: String, reassertionsLeft: Int = 1) {
        self.pageSettleTask?.cancel()
        self.pageSettleVideoId = videoId
        self.pageSettleReassertionsLeft = reassertionsLeft

        self.pageSettleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pageSettleDelay)
            guard let self, !Task.isCancelled else { return }
            guard self.pageSettleVideoId == videoId, self.pendingPlayVideoId == videoId else { return }

            SingletonPlayerWebView.shared.requestPageCurrentVideoId { [weak self] observedVideoId in
                self?.settlePagePlayback(expectedVideoId: videoId, observedVideoId: observedVideoId)
            }
        }
    }

    /// Applies what the page reported about the track it is playing.
    func settlePagePlayback(expectedVideoId: String, observedVideoId: String?) {
        // A paired video page plays the same track under another id; that is not a different track.
        let observed = observedVideoId.map { self.canonicalPlaybackVideoId(for: $0) ?? $0 }

        let decision = WebQueueSettleRules.decision(
            expectedVideoId: expectedVideoId,
            settledVideoId: self.pageSettleVideoId,
            observedVideoId: observed,
            reassertionsLeft: self.pageSettleReassertionsLeft
        )

        switch decision {
        case .idle:
            return
        case .confirmed:
            self.pageSettleVideoId = nil
            self.logger.debug("The page confirmed it is playing \(expectedVideoId)")
        case .reassert:
            self.pageSettleReassertionsLeft -= 1
            self.logger.info(
                "The page was playing \(observed ?? "unknown") instead of \(expectedVideoId); asking it again"
            )
            SingletonPlayerWebView.shared.playInPage(videoId: expectedVideoId) { [weak self] status in
                guard let self, self.pageSettleVideoId == expectedVideoId else { return }
                self.updatePagePlaybackCapability(status)
                guard !WebPagePlaybackStatus.succeeded(status) else { return }
                self.pageSettleVideoId = nil
                self.loadExpectedTrackPage(videoId: expectedVideoId)
            }
        case .load:
            self.pageSettleVideoId = nil
            self.logger.info("The page kept another track than \(expectedVideoId); loading its watch page")
            self.loadExpectedTrackPage(videoId: expectedVideoId)
        }
    }

    /// Loads the track Kaset is showing, if it is still the one being played.
    private func loadExpectedTrackPage(videoId: String) {
        guard self.pendingPlayVideoId == videoId else { return }
        SingletonPlayerWebView.shared.loadWatchPage(videoId: videoId)
    }
}
