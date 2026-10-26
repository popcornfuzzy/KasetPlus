import Foundation

// MARK: - WebPagePlaybackCapability

/// What the document in the player WebView can do about the track it is playing.
///
/// The page owns the player. Kaset used to change track by navigating to a new watch page, which
/// throws away the whole document — the JS bundle, the player, the DRM session, the player bar. The
/// page's player can swap the track inside the open document instead, and that is all Kaset ever asks
/// it to do: no queue is installed, and nothing of YouTube Music's own state is rewritten.
///
/// Whether it can is a property of the *document*, not of Kaset, so it is probed and recorded rather
/// than assumed. A page that cannot swap reports it and gets a navigation, which is what every track
/// change used to cost.
enum WebPagePlaybackCapability: Equatable {
    /// Nothing observed yet in this document.
    case unknown
    /// The page's player accepts a track change without a document load.
    case inPage
    /// The page has no usable player API: only a page load can change the track.
    case unavailable

    /// Whether the page can change track without a document load.
    var canSwapTrackInPage: Bool {
        self != .unavailable
    }
}

// MARK: - WebPagePlaybackStatus

/// The statuses the in-page player bridge answers with.
///
/// These are the contract with the page: they are what tells Kaset whether to trust the swap, and they
/// are the only reason a changed player API degrades to page loads instead of a stalled bar.
enum WebPagePlaybackStatus {
    /// The requested track was already the one playing.
    static let alreadyPlaying = "already-playing"
    /// The page's own queue already held the track, and the player jumped to it.
    static let playedAt = "played-at"
    /// The page's player loaded the track into the open document.
    static let loadedVideo = "loaded-video"
    /// There is no player API to ask.
    static let noPlayer = "no-player"
    /// The bridge was not installed in this document (it loads at document end).
    static let notInstalled = "not-installed"
    /// The player answered by throwing.
    static let failed = "error"

    private static let handled = [alreadyPlaying, playedAt, loadedVideo]

    /// Whether the page started the requested track itself.
    static func succeeded(_ status: String) -> Bool {
        self.handled.contains(status)
    }

    /// The capability a status proves for this document.
    static func capability(of status: String) -> WebPagePlaybackCapability {
        self.succeeded(status) ? .inPage : .unavailable
    }
}

// MARK: - WebQueueSettleDecision

/// What Kaset does after checking that the page really started the track it asked for.
///
/// A track start is a command, not a result. The page can answer `loaded-video` and then keep playing
/// what it was playing — its own end-of-track advance, a rejected load, a page about to be replaced —
/// and a bar that believes the answer would show one song while another one plays. Checking once,
/// shortly after the start, is what keeps the two in agreement without waiting for a metadata
/// observation that may never come.
enum WebQueueSettleDecision: Equatable {
    /// Nothing to settle: another track was started, or the page said nothing it can be held to.
    case idle
    /// The page is playing the row Kaset started.
    case confirmed
    /// The page is playing another track: put Kaset's row back, in place.
    case reassert
    /// The page kept another track even after being put back: load the row the long way.
    case load
}

// MARK: - WebQueueSettleRules

/// The decision behind ``WebQueueSettleDecision``, free of the WebView so it can be tested without a page.
enum WebQueueSettleRules {
    /// Decides what a page that was asked to play `expectedVideoId` needs.
    ///
    /// - Parameter settledVideoId: the track Kaset is still waiting on, if it is still waiting on one.
    ///   A newer track start replaces it, and an answer about the older track settles nothing.
    /// - Parameter observedVideoId: what the page reports it is playing (`nil` when it said nothing).
    /// - Parameter reassertionsLeft: how many in-place corrections are still allowed.
    static func decision(
        expectedVideoId: String,
        settledVideoId: String?,
        observedVideoId: String?,
        reassertionsLeft: Int
    ) -> WebQueueSettleDecision {
        guard settledVideoId == expectedVideoId else { return .idle }
        guard let observedVideoId, !observedVideoId.isEmpty else { return .idle }
        guard observedVideoId != expectedVideoId else { return .confirmed }
        return reassertionsLeft > 0 ? .reassert : .load
    }
}
