import Foundation

// MARK: - KaraokeTiming

/// Tunable timing constants for the karaoke lyrics animation.
///
/// Kept in one place so the fill feel can be tuned without hunting through the
/// renderer, and so tests can drive the model with their own values.
struct KaraokeTiming: Equatable, Sendable {
    /// How far ahead of a word's timestamp its fill starts moving, in milliseconds.
    /// Provider timings mark onsets, so leading the fill slightly means the edge is
    /// already moving by the time the word is heard.
    var attackLeadMs: Double = 70

    /// How far before a word's end its fill finishes, so a word completes just as
    /// the next one starts filling.
    var releaseTailMs: Double = 40

    /// Shortest fill ramp, so even a clipped word visibly fills instead of popping.
    var minimumFillMs: Double = 90

    /// Longest fill ramp between two word onsets. Providers timestamp onsets only,
    /// so an unusually long gap should settle rather than crawl across the screen.
    var maximumFillMs: Double = 1200

    /// Fill ramp for a word whose line has no usable duration.
    var fallbackWordMs: Double = 420

    /// Fill ramp for a whole line whose duration is unknown.
    var fallbackLineMs: Double = 3000

    /// How long the emphasis on the line being sung is given to rise and settle, in
    /// milliseconds.
    ///
    /// The lift rides one *crest* at a time: the shortest run of characters whose own fill
    /// lasts this long (`KaraokeFillModel.crests(of:minimumDurationMs:)`), which is then
    /// carried as one. It used to ride a single character's slice of the word's window,
    /// and on a fast line that slice is 60–90 ms — so a character popped up and back down
    /// within two or three display frames and the next one took over, ten to thirteen
    /// times a second. A crest of this length rises and falls over several frames each,
    /// which is slow enough to read as a wave rather than as a flicker. Text slow enough
    /// to give one character this much time keeps lifting one character at a time.
    var minimumCrestMs: Double = 250

    /// A new sample this far from the display clock is a seek or a track change,
    /// not sample jitter.
    var snapThresholdMs: Double = 400

    /// Sample error is spread over this window: the clock changes speed rather than
    /// jumping, so a late sample costs a brief catch-up instead of a visible skip.
    var correctionWindowMs: Double = 250

    /// Fastest the clock may run ahead of (or behind) its nominal rate while
    /// correcting. Below 1.0 so the highlight never rewinds on jitter.
    var maximumRateBias: Double = 0.4

    /// Longest the clock extrapolates past its newest sample before stalling, so a
    /// stalled poll cannot race the highlight down the page.
    var maximumExtrapolationMs: Double = 2000

    /// Longest frame delta applied to the clock, so a rendering hitch cannot
    /// teleport the highlight.
    var maximumFrameMs: Double = 100

    /// How far before a line begins the sheet starts travelling to it, in milliseconds.
    ///
    /// This is the whole of the lead: the sheet is a column of one line's height per line, so a
    /// line that is about to be sung has to be brought into place *before* it is sung — it cannot
    /// be scrolled to on the frame its first word lands. The value is Better Lyrics' own
    /// (`--blyrics-lyric-ending-threshold` / `--blyrics-scroll-timing-offset`, both `0.5 s`).
    ///
    /// It is deliberately **not** the lead on the emphasis. The line being sung keeps the
    /// highlight until the next line's first content opens, which is the moment the baton passes:
    /// one bright line is always the line being read, and it never starts to leave while it is
    /// still filling.
    var scrollLeadMs: Double = 500

    /// How long the sheet takes to travel from one line to the next, in milliseconds.
    ///
    /// Shorter than `scrollLeadMs` on purpose, with the difference absorbing a late playback
    /// sample: the travel is always over before the line it is travelling to is sung.
    var scrollDurationMs: Double = 400

    /// How far before the line after the one being sung has anything to show that it takes
    /// the display clock.
    ///
    /// The row after the current one used to run on the clock for the whole of the line
    /// before it, drawing a frame identical to the one already on screen until its own first
    /// word came round — twice the frames of a row that is actually moving, for none of the
    /// picture. It now takes the clock just before its own first ramp opens, with this margin
    /// absorbing a late playback sample so its fill is never first seen part-way through its
    /// first word. The margin is deliberately smaller than the shortest line.
    var armLeadMs: Double = 150

    static let standard = KaraokeTiming()
}

// MARK: - LyricsClockSample

/// One playback position sample from the hidden WebView's high-frequency lyrics poll.
struct LyricsClockSample: Equatable, Sendable {
    /// When the sample reached the app.
    let hostTime: Date
    /// Playback position reported by the player, in milliseconds.
    let timeMs: Int
    /// Whether playback was running when the sample was taken.
    let isPlaying: Bool
}

// MARK: - LyricsPlaybackClock

/// Turns the WebView's 10 Hz playback samples into a continuous, display-synced
/// clock for the karaoke highlight.
///
/// Rendering straight from the samples makes the fill step once per poll, and a
/// late or out-of-order sample makes it jump. This clock instead advances on its
/// own between samples and absorbs sample error by *changing its rate*: a sample
/// that lands 120 ms late costs a brief catch-up, not a visible skip. Seeks and
/// track changes snap, because there the sample really has moved.
///
/// Not `@Observable` on purpose: views read it inside `TimelineView`, so mutating
/// it must not invalidate the view hierarchy.
final class LyricsPlaybackClock {
    private let timing: KaraokeTiming
    private var anchor: LyricsClockSample?
    private var displayMs: Double?
    private var lastFrameDate: Date?

    init(timing: KaraokeTiming = .standard) {
        self.timing = timing
    }

    /// The most recent position the clock has been advanced to.
    var displayPositionMs: Double { self.displayMs ?? 0 }

    /// Records a playback sample.
    ///
    /// A sample that disagrees with the display clock by more than
    /// `KaraokeTiming.snapThresholdMs` is treated as a seek: the display position
    /// follows it immediately. Everything smaller is corrected by slewing.
    func receive(_ sample: LyricsClockSample) {
        defer { self.anchor = sample }

        guard let displayMs = self.displayMs else {
            self.displayMs = Double(sample.timeMs)
            return
        }

        let projected = self.projectedPositionMs(sample, at: sample.hostTime)
        if abs(projected - displayMs) > self.timing.snapThresholdMs {
            self.displayMs = projected
        }
    }

    /// Advances the clock to a display frame and returns the position to render.
    @discardableResult
    func advance(to date: Date) -> Double {
        guard let anchor = self.anchor else { return 0 }

        guard let currentDisplayMs = self.displayMs else {
            let start = Double(anchor.timeMs)
            self.displayMs = start
            self.lastFrameDate = date
            return start
        }

        // The first frame establishes the frame origin without moving the highlight,
        // so starting or resetting the clock never steps the fill forward.
        guard let lastFrame = self.lastFrameDate else {
            self.lastFrameDate = date
            return currentDisplayMs
        }

        let target = self.projectedPositionMs(anchor, at: date)
        let error = target - currentDisplayMs
        defer { self.lastFrameDate = date }

        if abs(error) > self.timing.snapThresholdMs {
            self.displayMs = target
            return target
        }

        let frameMs = min(max(date.timeIntervalSince(lastFrame) * 1000, 0), self.timing.maximumFrameMs)
        guard frameMs > 0 else { return currentDisplayMs }

        let bias = min(
            max(error / self.timing.correctionWindowMs, -self.timing.maximumRateBias),
            self.timing.maximumRateBias
        )
        let rate = (anchor.isPlaying ? 1.0 : 0.0) + bias
        // Only a seek moves the highlight backwards, so the fill never un-fills.
        let displayMs = currentDisplayMs + max(0, rate) * frameMs
        self.displayMs = displayMs
        return displayMs
    }

    /// Clears the clock, for a new track.
    func reset() {
        self.anchor = nil
        self.displayMs = nil
        self.lastFrameDate = nil
    }

    private func projectedPositionMs(_ sample: LyricsClockSample, at date: Date) -> Double {
        guard sample.isPlaying else { return Double(sample.timeMs) }
        let elapsed = date.timeIntervalSince(sample.hostTime) * 1000
        return Double(sample.timeMs) + min(max(elapsed, 0), self.timing.maximumExtrapolationMs)
    }
}
