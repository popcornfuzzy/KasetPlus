import CoreGraphics
import Foundation

// MARK: - RichLyricsTiming

/// The constants of the Better Lyrics word animation, in one place.
///
/// Every value is the one the Better Lyrics renderer ships — its `packages/core/src/styles/variables.css`
/// and `packages/core/src/engine.ts` in <https://github.com/better-lyrics/braccato> — so the look can be
/// compared with theirs rather than with a re-tuned imitation of it. They are kept here rather than in
/// the view so the envelopes they describe can be asserted on without rendering anything.
struct RichLyricsTiming: Equatable, Sendable {
    // MARK: Swipe

    /// How far ahead of a word its swipe starts, as a share of the word's own duration.
    var swipeLeadRatio: Double = 0.1

    /// How long the swipe takes, as a share of the word's duration. Above 1, so a word is still
    /// arriving as the next one begins and the highlight never stops moving through a line.
    var swipeDurationRatio: Double = 1.6

    /// Where the lit edge of the highlight sits at the start and at the end of the swipe, as a
    /// share of the word's width. It begins off the leading edge and finishes past the trailing
    /// one, so a word starts lighting just as it is sung and is fully lit before the swipe ends.
    var swipeLitFrom: Double = -0.2
    var swipeLitTo: Double = 1.4

    /// Where the highlight has faded to nothing at the start and at the end of the swipe. The band
    /// between the two is always a tenth of the word wide: a crisp edge, not a wash.
    var swipeTailFrom: Double = -0.1
    var swipeTailTo: Double = 1.5

    // MARK: Word wobble

    /// How long the whole word takes to pop and settle.
    var wobbleDurationMs: Double = 1000
    /// Where in that time the word reaches its peak, and where it is back at rest.
    var wobblePeakOffset: Double = 0.125
    var wobbleSettleOffset: Double = 0.75
    /// Peak sideways travel of the word, as a share of its font size.
    ///
    /// Better Lyrics slides the word `0.05em` to the trailing edge on the way up. That is the one
    /// thing in the animation that moves text sideways, and across a sheet of constantly sung words
    /// it reads as a jitter rather than as a word being sung, so it is off: the word still widens
    /// (below), which is the part of the pop that reads as emphasis rather than as movement.
    var wobbleTravelEm: Double = 0
    /// Peak horizontal scale of the word, about its own centre.
    var wobbleScale: Double = 1.025

    // MARK: Letter wave

    /// How long a letter's own float takes when the swipe leaves it the time.
    var letterWaveDurationMs: Double = 900
    /// Where in a letter's float it crests.
    var letterWaveCrestOffset: Double = 0.4
    /// Crest height of a floating letter, as a share of the font size.
    var letterWaveLiftEm: Double = 0.05
    /// Where a letter comes to rest once its float is over, while its word is still being sung.
    /// The whole word drops back onto the baseline when it has finished.
    var letterWaveSettleEm: Double = 0.02

    /// A word held at least this long is a **long word**: its letters swell at the crest, which is
    /// the one detail a held syllable gets that a short one does not. Better Lyrics' default
    /// `blyrics-long-word-threshold`, in milliseconds.
    var longWordThresholdMs: Double = 900
    /// The scale a long word's letters reach at their crest.
    var longWordScale: Double = 1.11

    // MARK: Glow

    /// How long the bloom lasts: the longer of this share of the word and the floor below.
    var glowDurationRatio: Double = 1.2
    var glowMinimumDurationMs: Double = 1200
    /// Blur radius at full strength, as a share of the font size. Better Lyrics' `0.8rem` against
    /// its `3rem` line, so the bloom is the same shape at the panel's size and the player's.
    var glowRadiusEm: Double = 0.8 / 3
    /// Opacity of the bloom at full strength.
    var glowOpacity: Double = 0.5

    // MARK: Line-synced

    /// How long a line the provider timed only as a whole takes to appear.
    var lineFadeInMs: Double = 330

    static let standard = RichLyricsTiming()

    /// Better Lyrics' own pop: the whole word slides `0.05em` towards its trailing edge while it
    /// widens.
    ///
    /// Only the travel differs from `standard` — that value is Better Lyrics' own, not a range to
    /// tune — so a reader who asks for the slide gets exactly the animation they had without it,
    /// plus the slide.
    static let withWordSlide: RichLyricsTiming = {
        var timing = RichLyricsTiming()
        timing.wobbleTravelEm = 0.05
        return timing
    }()
}

// MARK: - RichLyricsCurve

/// The CSS easings the Better Lyrics animations use, evaluated as plain curves.
///
/// The model stays free of SwiftUI so the envelopes can be asserted on directly, and a cubic
/// Bézier is four numbers and a bisection rather than a framework dependency.
enum RichLyricsCurve: Sendable {
    case linear
    /// CSS `ease`.
    case ease
    /// CSS `ease-in-out`.
    case easeInOut
    /// CSS `ease-out`.
    case easeOut

    /// The curve's value for a progress along its own span, clamped to 0...1 in and out.
    func value(at progress: Double) -> Double {
        let x = min(max(progress, 0), 1)
        guard x > 0, x < 1 else { return x }
        guard let points = self.controlPoints else { return x }
        let (x1, y1, x2, y2) = points
        // The curve is parameterised by its own `t`, not by `x`: solve for the `t` whose `x` is
        // the progress asked for, then evaluate `y` there.
        var low = 0.0
        var high = 1.0
        var t = x
        for _ in 0 ..< 24 {
            let estimate = Self.curve(t, x1, x2)
            if abs(estimate - x) < 0.0001 { break }
            if estimate < x {
                low = t
            } else {
                high = t
            }
            t = (low + high) / 2
        }
        return Self.curve(t, y1, y2)
    }

    /// The two control points of the cubic Bézier, or `nil` for a straight line.
    private var controlPoints: (Double, Double, Double, Double)? {
        switch self {
        case .linear: nil
        case .ease: (0.25, 0.1, 0.25, 1)
        case .easeInOut: (0.42, 0, 0.58, 1)
        case .easeOut: (0, 0, 0.58, 1)
        }
    }

    /// One axis of a cubic Bézier whose end points are 0 and 1.
    private static func curve(_ t: Double, _ first: Double, _ second: Double) -> Double {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * first
            + 3 * inverse * t * t * second
            + t * t * t
    }
}

// MARK: - RichLyricsSwipe

/// The window a word's highlight swipes over.
struct RichLyricsSwipe: Equatable, Sendable {
    let startMs: Double
    let durationMs: Double
}

// MARK: - RichLyricsBand

/// The highlight's gradient over a word at one moment, in shares of the word's width.
///
/// Measured in reading order, so a right-to-left word fills from its trailing edge for free: the
/// caller draws the same band from the other side.
struct RichLyricsBand: Equatable, Sendable {
    /// Everything before this is sung.
    let lit: Double
    /// From here the highlight has faded to nothing.
    let tail: Double

    /// Nothing on the word is lit yet.
    var isUnlit: Bool {
        self.tail <= 0
    }

    /// The whole word is lit — before the swipe itself has finished, because it overshoots.
    var isFullyLit: Bool {
        self.lit >= 1
    }
}

// MARK: - RichLyricsWobble

/// How far the whole word has popped, at one moment.
struct RichLyricsWobble: Equatable, Sendable {
    /// Travel to the trailing edge, as a share of the font size.
    var travelEm: Double = 0
    /// Horizontal scale about the word's own centre.
    var scale: Double = 1

    static let identity = RichLyricsWobble()
}

// MARK: - RichLyricsLetterWave

/// When one letter of a word starts to float, and for how long.
struct RichLyricsLetterWave: Equatable, Sendable {
    /// Start of the float, in milliseconds from the word's own start. May be before it.
    let startMs: Double
    let durationMs: Double
}

// MARK: - RichLyricsLetterFloat

/// Where one letter sits at one moment.
struct RichLyricsLetterFloat: Equatable, Sendable {
    /// Height above the letter's rest position, as a share of the font size.
    let liftEm: Double
    let scale: Double

    static let rest = RichLyricsLetterFloat(liftEm: 0, scale: 1)

    var isResting: Bool {
        self.liftEm == 0 && self.scale == 1
    }
}

// MARK: - RichLyricsAnimation

/// The envelopes behind the Better Lyrics word animation: the swipe, the word's pop, the wave
/// through its letters, and the bloom that settles behind them.
///
/// The words and their fill windows are `KaraokeFillModel`'s, so both styles animate the same
/// timings; this only decides what each of those windows looks like while it is being sung.
enum RichLyricsAnimation {
    // MARK: Swipe

    /// The window a word's highlight swipes over: it starts one lead before the word and runs
    /// longer than the word does.
    static func swipe(for word: KaraokeWord, timing: RichLyricsTiming = .standard) -> RichLyricsSwipe {
        let duration = max(1, word.durationMs)
        return RichLyricsSwipe(
            startMs: word.fillStartMs - timing.swipeLeadRatio * duration,
            durationMs: duration * timing.swipeDurationRatio
        )
    }

    /// How far through its swipe a word is at a playback position, 0...1.
    ///
    /// Linear on purpose: the band below is what moves, and it moves at a constant speed so the
    /// highlight reads as one sweep through a line rather than as a per-word animation.
    static func progress(of swipe: RichLyricsSwipe, at timeMs: Double) -> Double {
        min(max((timeMs - swipe.startMs) / max(1, swipe.durationMs), 0), 1)
    }

    /// The gradient over a word at a swipe progress.
    static func band(at progress: Double, timing: RichLyricsTiming = .standard) -> RichLyricsBand {
        let clamped = min(max(progress, 0), 1)
        return RichLyricsBand(
            lit: timing.swipeLitFrom + (timing.swipeLitTo - timing.swipeLitFrom) * clamped,
            tail: timing.swipeTailFrom + (timing.swipeTailTo - timing.swipeTailFrom) * clamped
        )
    }

    /// The gradient over a word at a playback position.
    static func band(
        for word: KaraokeWord,
        at timeMs: Double,
        timing: RichLyricsTiming = .standard
    ) -> RichLyricsBand {
        self.band(at: self.progress(of: self.swipe(for: word, timing: timing), at: timeMs), timing: timing)
    }

    // MARK: Word wobble

    /// How far a word has popped at a playback position.
    ///
    /// The word widens slightly, is back at rest by three quarters of the animation, and stays
    /// there for the rest of it — so a word is settled before the next one starts. It does not
    /// travel sideways (`RichLyricsTiming.wobbleTravelEm`).
    static func wobble(
        for word: KaraokeWord,
        at timeMs: Double,
        timing: RichLyricsTiming = .standard
    ) -> RichLyricsWobble {
        let elapsed = timeMs - word.fillStartMs
        guard elapsed > 0, elapsed < timing.wobbleDurationMs else { return .identity }
        let progress = elapsed / timing.wobbleDurationMs

        if progress < timing.wobblePeakOffset {
            let rise = RichLyricsCurve.easeInOut.value(at: progress / timing.wobblePeakOffset)
            return RichLyricsWobble(
                travelEm: timing.wobbleTravelEm * rise,
                scale: 1 + (timing.wobbleScale - 1) * rise
            )
        }
        if progress < timing.wobbleSettleOffset {
            let fall = RichLyricsCurve.easeOut.value(
                at: (progress - timing.wobblePeakOffset) / (timing.wobbleSettleOffset - timing.wobblePeakOffset)
            )
            return RichLyricsWobble(
                travelEm: timing.wobbleTravelEm * (1 - fall),
                scale: 1 + (timing.wobbleScale - 1) * (1 - fall)
            )
        }
        return .identity
    }

    // MARK: Letter wave

    /// When each letter of a word floats, in reading order.
    ///
    /// A letter starts as the swipe touches it and crests **when the swipe finishes lighting it**:
    /// when the swipe lights a letter faster than the float's own rise, the float starts later and
    /// keeps its standard length; when the swipe takes longer — which is what a held word does —
    /// the float is stretched so its crest still lands on that moment. That stretch is the detail a
    /// long word gets: its letters are still rising and falling while the syllable is held, where a
    /// short word's are already settled.
    static func letterWaves(
        for word: KaraokeWord,
        letterCount: Int,
        timing: RichLyricsTiming = .standard
    ) -> [RichLyricsLetterWave] {
        guard letterCount > 0 else { return [] }
        let swipe = self.swipe(for: word, timing: timing)
        let lead = timing.swipeLeadRatio * max(1, word.durationMs)
        let riseMs = timing.letterWaveDurationMs * timing.letterWaveCrestOffset
        let count = Double(letterCount)

        return (0 ..< letterCount).map { index in
            // The swipe's windows are measured from the start of the swipe, which is one lead
            // ahead of the word; the word's own start is what a float is scheduled from.
            let touchedMs = self.timeWhenTailPasses(Double(index) / count, swipe: swipe, timing: timing) - lead
            let litMs = self.timeWhenLitPasses(Double(index + 1) / count, swipe: swipe, timing: timing) - lead

            if litMs - riseMs > touchedMs {
                return RichLyricsLetterWave(
                    startMs: touchedMs,
                    durationMs: (litMs - touchedMs) / timing.letterWaveCrestOffset
                )
            }
            return RichLyricsLetterWave(startMs: litMs - riseMs, durationMs: timing.letterWaveDurationMs)
        }
    }

    /// Where one letter sits at a playback position.
    ///
    /// While its float runs it rises on `ease-in-out` to the crest and falls on `ease-out` most of
    /// the way back, to the rest it holds once the float is over: a letter stays just above the
    /// baseline for as long as its line is being sung, which is what Better Lyrics gets from leaving
    /// the finished animation in place. A line that is no longer being sung draws every letter on
    /// the baseline instead (`KaraokeLyricsLineView.isSettled`), so a finished line is level with the
    /// sheet rather than a little above it.
    static func letterFloat(
        of wave: RichLyricsLetterWave,
        word: KaraokeWord,
        at timeMs: Double,
        timing: RichLyricsTiming = .standard
    ) -> RichLyricsLetterFloat {
        let elapsed = timeMs - word.fillStartMs
        guard elapsed > wave.startMs else { return .rest }

        let progress = (elapsed - wave.startMs) / max(1, wave.durationMs)
        if progress >= 1 {
            return RichLyricsLetterFloat(liftEm: timing.letterWaveSettleEm, scale: 1)
        }

        let isLongWord = word.durationMs >= timing.longWordThresholdMs
        let scaleWidth = isLongWord ? timing.longWordScale - 1 : 0

        if progress < timing.letterWaveCrestOffset {
            let rise = RichLyricsCurve.easeInOut.value(at: progress / timing.letterWaveCrestOffset)
            return RichLyricsLetterFloat(
                liftEm: timing.letterWaveLiftEm * rise,
                scale: 1 + scaleWidth * rise
            )
        }

        let fall = RichLyricsCurve.easeOut.value(
            at: (progress - timing.letterWaveCrestOffset) / (1 - timing.letterWaveCrestOffset)
        )
        return RichLyricsLetterFloat(
            liftEm: timing.letterWaveLiftEm
                + (timing.letterWaveSettleEm - timing.letterWaveLiftEm) * fall,
            scale: 1 + scaleWidth * (1 - fall)
        )
    }

    /// When the highlight's trailing edge — the moment a letter starts to light — reaches a share
    /// of the word's width, in milliseconds from the start of the swipe.
    private static func timeWhenTailPasses(
        _ share: Double,
        swipe: RichLyricsSwipe,
        timing: RichLyricsTiming
    ) -> Double {
        let span = timing.swipeTailTo - timing.swipeTailFrom
        guard abs(span) > .ulpOfOne else { return 0 }
        let time = swipe.durationMs * (share - timing.swipeTailFrom) / span
        return min(max(time, 0), swipe.durationMs)
    }

    /// When the highlight's lit edge — the moment a letter is fully lit — reaches a share of the
    /// word's width, in milliseconds from the start of the swipe.
    private static func timeWhenLitPasses(
        _ share: Double,
        swipe: RichLyricsSwipe,
        timing: RichLyricsTiming
    ) -> Double {
        let span = timing.swipeLitTo - timing.swipeLitFrom
        guard abs(span) > .ulpOfOne else { return 0 }
        let time = swipe.durationMs * (share - timing.swipeLitFrom) / span
        return min(max(time, 0), swipe.durationMs)
    }

    // MARK: Glow

    /// Strength of the bloom behind a word, 0...1.
    ///
    /// Better Lyrics animates the glow's blur radius from `0.8rem` down to nothing over the longer
    /// of `1.2 ×` the word and 1.2 s. A radius that changes every frame would re-rasterise the
    /// blurred layer every frame, so the radius is fixed and the bloom fades instead: the same
    /// shape, settling at the same moment, at a fraction of the cost.
    static func glow(
        for word: KaraokeWord,
        at timeMs: Double,
        timing: RichLyricsTiming = .standard
    ) -> Double {
        let duration = max(word.durationMs * timing.glowDurationRatio, timing.glowMinimumDurationMs)
        let elapsed = timeMs - word.fillStartMs
        guard elapsed > 0, elapsed < duration else { return 0 }
        return 1 - RichLyricsCurve.ease.value(at: elapsed / duration)
    }

    // MARK: Shared layers

    /// How far apart two letters of one word may be, in points, before they have to be drawn as
    /// two layers: a quarter of a point, the same threshold the Apple Music style uses to decide
    /// whether its crest is worth cutting out of the word at all.
    static let visibleLiftPoints: CGFloat = 0.25

    /// How far apart two letters' scales may be before they have to be drawn separately. A
    /// hundredth of a letter's width is a fraction of a point even on the player's text.
    static let visibleScaleSpread: Double = 0.02

    /// One float for the whole word, when its letters are close enough in height that no display
    /// can show the difference — otherwise `nil`, and every letter keeps its own.
    ///
    /// A word whose letters differ by less than a quarter point is drawn as one text layer instead
    /// of one per letter. That matters on a line timed per syllable: its units are short, so their
    /// floats are still running long after the units themselves are sung, and every one of them
    /// would otherwise be several layers for most of the line. The mean lift is used rather than the
    /// first letter's, so the shared word sits in the middle of the wave it stands for.
    ///
    /// The shared layer **only rises**. It keeps no scale, because scaling one layer widens the word
    /// about its own centre and every glyph in it then moves sideways — which is the one thing the
    /// pop must not do when the reader has not asked for the slide, and a movement that a per-letter
    /// layer never had, since a letter swells about its own cell. A long word's letter swell is a
    /// *letter* effect and is drawn per letter, where it is the same size as the rest of the wave.
    static func sharedFloat(of floats: [RichLyricsLetterFloat], fontSize: CGFloat) -> RichLyricsLetterFloat? {
        guard let first = floats.first else { return nil }
        guard floats.count > 1 else { return first }
        let lifts = floats.map(\.liftEm)
        let scales = floats.map(\.scale)
        guard let lowestLift = lifts.min(), let highestLift = lifts.max(),
              let lowestScale = scales.min(), let highestScale = scales.max()
        else { return nil }

        let toleranceEm = fontSize > 0 ? Double(Self.visibleLiftPoints / fontSize) : 0
        guard highestLift - lowestLift <= toleranceEm, highestScale - lowestScale <= Self.visibleScaleSpread else {
            return nil
        }
        let count = Double(floats.count)
        return RichLyricsLetterFloat(liftEm: lifts.reduce(0, +) / count, scale: 1)
    }

    // MARK: Static frames

    /// The display position a word must be drawn at: its live position while anything on it can
    /// still change, and a frozen one once nothing can.
    ///
    /// A word's picture is a function of the display clock, but at the end of its life that
    /// function returns the same one forever: once the swipe has run off the word, the pop is back
    /// at rest, the bloom is out and every letter's float is over, every frame after it draws the
    /// frame it settles to. Handing the word that position instead of the moving one is what keeps
    /// a line of many short units — a duet is timed per syllable, so its units are sung long
    /// before their floats and blooms are over — from re-drawing every unit of itself on every
    /// frame: a finished word compares equal from one frame to the next, so only the few that are
    /// still moving are drawn again.
    ///
    /// A word the fill has not reached is deliberately **not** frozen. It is one dim text layer
    /// with nothing moving on it either, but freezing it was measured to make the frame dearer,
    /// not cheaper — the bookkeeping of a per-word constant costs more than the layer it saves.
    static func renderTimeMs(
        for word: KaraokeWord,
        waves: [RichLyricsLetterWave],
        at timeMs: Double,
        timing: RichLyricsTiming = .standard
    ) -> Double {
        let settled = self.settledTimeMs(for: word, waves: waves, timing: timing)
        return timeMs >= settled ? settled : timeMs
    }

    /// The first position at which nothing on a word can move any more: its swipe has run off the
    /// word, its pop is back at rest, its bloom is out and every letter's float is over. Every
    /// frame after it is the one frame this position draws.
    static func settledTimeMs(
        for word: KaraokeWord,
        waves: [RichLyricsLetterWave],
        timing: RichLyricsTiming = .standard
    ) -> Double {
        let swipe = self.swipe(for: word, timing: timing)
        let glow = max(word.durationMs * timing.glowDurationRatio, timing.glowMinimumDurationMs)
        var settlesAt = max(timing.wobbleDurationMs, glow)
        settlesAt = max(settlesAt, swipe.startMs - word.fillStartMs + swipe.durationMs)
        for wave in waves {
            settlesAt = max(settlesAt, wave.startMs + wave.durationMs)
        }
        return word.fillStartMs + settlesAt
    }

    // MARK: Line-synced

    /// How far a line the provider timed only as a whole has faded in, 0...1.
    static func lineFadeIn(
        for word: KaraokeWord,
        at timeMs: Double,
        timing: RichLyricsTiming = .standard
    ) -> Double {
        let elapsed = timeMs - word.fillStartMs
        guard elapsed > 0 else { return 0 }
        return RichLyricsCurve.ease.value(at: elapsed / max(1, timing.lineFadeInMs))
    }
}
