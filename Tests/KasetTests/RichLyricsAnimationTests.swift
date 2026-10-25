import Foundation
import Testing
@testable import Kaset

/// The envelopes behind the Better Lyrics word animation, held to what the renderer draws.
///
/// These are arithmetic, so they are asserted directly rather than through pixels: the look the
/// pixels carry is `RichLyricsRenderTests`' business, and the timing it is built from is this
/// suite's.
@Suite(.tags(.model))
struct RichLyricsAnimationTests {
    private static let timing = RichLyricsTiming.standard

    /// A word sung over `durationMs` from 1000 ms, which is where most of these tests drive it.
    private static func word(durationMs: Double = 400, startMs: Double = 1000) -> KaraokeWord {
        KaraokeWord(
            index: 0,
            text: "Sing",
            isNewWord: true,
            fillStartMs: startMs,
            fillEndMs: startMs + durationMs
        )
    }

    /// When a letter is fully lit, measured from the word's own start — the test's own arithmetic,
    /// so it can disagree with the model.
    private static func litTime(
        of index: Int,
        of count: Int,
        word: KaraokeWord
    ) -> Double {
        let swipe = RichLyricsAnimation.swipe(for: word, timing: Self.timing)
        let share = Double(index + 1) / Double(count)
        let fromSwipe = swipe.durationMs
            * (share - Self.timing.swipeLitFrom)
            / (Self.timing.swipeLitTo - Self.timing.swipeLitFrom)
        let clamped = min(max(fromSwipe, 0), swipe.durationMs)
        return clamped - Self.timing.swipeLeadRatio * word.durationMs
    }

    // MARK: Swipe

    @Test("The swipe starts before its word and outlasts it")
    func swipeLeadsAndOverruns() {
        let word = Self.word(durationMs: 400, startMs: 1_000)
        let swipe = RichLyricsAnimation.swipe(for: word, timing: Self.timing)

        #expect(abs(swipe.startMs - 960) < 0.001, "the swipe began at \(swipe.startMs) instead of a lead before the word")
        #expect(abs(swipe.durationMs - 640) < 0.001, "the swipe lasted \(swipe.durationMs) instead of 1.6 words")
        #expect(swipe.startMs + swipe.durationMs > word.fillEndMs, "the swipe was over before the word was")
    }

    @Test("The band sweeps off the leading edge and past the trailing one, at a constant speed")
    func bandSweepsThroughTheWord() {
        let atStart = RichLyricsAnimation.band(at: 0, timing: Self.timing)
        #expect(abs(atStart.lit - -0.2) < 1e-9)
        #expect(abs(atStart.tail - -0.1) < 1e-9)
        #expect(atStart.isUnlit, "a word started out already lit")

        let half = RichLyricsAnimation.band(at: 0.5, timing: Self.timing)
        #expect(abs(half.lit - 0.6) < 1e-9)
        #expect(abs(half.tail - 0.7) < 1e-9)

        let atEnd = RichLyricsAnimation.band(at: 1, timing: Self.timing)
        #expect(abs(atEnd.lit - 1.4) < 1e-9)
        #expect(abs(atEnd.tail - 1.5) < 1e-9)
        #expect(atEnd.isFullyLit)

        // The edge is a tenth of the word wide from cover to cover, which is what keeps it crisp,
        // and it only ever moves forwards.
        var previous = atStart.lit
        for step in 0 ... 100 {
            let band = RichLyricsAnimation.band(at: Double(step) / 100, timing: Self.timing)
            #expect(abs((band.tail - band.lit) - 0.1) < 1e-9, "the band was \(band.tail - band.lit) wide at \(step)%")
            #expect(band.lit > previous || step == 0, "the fill went backwards at \(step)%")
            previous = band.lit
        }
    }

    @Test("A word is fully lit before its swipe has finished")
    func wordIsFullyLitBeforeTheSwipeEnds() {
        let threshold = (1 - Self.timing.swipeLitFrom) / (Self.timing.swipeLitTo - Self.timing.swipeLitFrom)
        #expect(!RichLyricsAnimation.band(at: threshold - 0.01, timing: Self.timing).isFullyLit)
        #expect(RichLyricsAnimation.band(at: threshold + 0.01, timing: Self.timing).isFullyLit)
        #expect(threshold < 1, "the swipe would have to finish before the word was lit")
    }

    // MARK: Word wobble

    @Test("A word pops once and is settled well before it finishes")
    func wordPopsAndSettles() {
        let word = Self.word(durationMs: 400, startMs: 1_000)
        let timing = Self.timing

        #expect(RichLyricsAnimation.wobble(for: word, at: 1_000, timing: timing) == .identity)

        let peak = RichLyricsAnimation.wobble(
            for: word,
            at: 1_000 + timing.wobbleDurationMs * timing.wobblePeakOffset,
            timing: timing
        )
        #expect(abs(peak.scale - timing.wobbleScale) < 1e-9, "the pop scaled to \(peak.scale)")
        // The word widens, it does not slide: sideways travel is the part that read as a jitter.
        #expect(peak.travelEm == 0, "the pop travelled \(peak.travelEm) em sideways")
        #expect(timing.wobbleTravelEm == 0)

        // Halfway back it is still moving, and at the settle offset it has stopped.
        let falling = RichLyricsAnimation.wobble(
            for: word,
            at: 1_000 + timing.wobbleDurationMs * (timing.wobblePeakOffset + timing.wobbleSettleOffset) / 2,
            timing: timing
        )
        #expect(falling.travelEm == 0)
        #expect(falling.scale > 1 && falling.scale < timing.wobbleScale)

        let settled = RichLyricsAnimation.wobble(
            for: word,
            at: 1_000 + timing.wobbleDurationMs * timing.wobbleSettleOffset,
            timing: timing
        )
        #expect(settled == .identity)
        #expect(RichLyricsAnimation.wobble(for: word, at: 5_000, timing: timing) == .identity)
    }

    @Test("The slide is Better Lyrics' own amount, and changes nothing else")
    func wordSlideOnlyAddsTravel() {
        let plain = RichLyricsTiming.standard
        let sliding = RichLyricsTiming.withWordSlide

        #expect(plain.wobbleTravelEm == 0)
        #expect(abs(sliding.wobbleTravelEm - 0.05) < 1e-12, "the slide is \(sliding.wobbleTravelEm) em, not Better Lyrics' 0.05")
        #expect(sliding.wobbleScale == plain.wobbleScale)
        #expect(sliding.wobbleDurationMs == plain.wobbleDurationMs)
        #expect(sliding.letterWaveLiftEm == plain.letterWaveLiftEm)
        #expect(sliding.longWordScale == plain.longWordScale)

        let word = Self.word(durationMs: 400, startMs: 1_000)
        let peakTime = 1_000 + sliding.wobbleDurationMs * sliding.wobblePeakOffset
        let slid = RichLyricsAnimation.wobble(for: word, at: peakTime, timing: sliding)
        #expect(abs(slid.travelEm - 0.05) < 1e-9, "the sliding word travelled \(slid.travelEm) em")
        #expect(abs(slid.scale - sliding.wobbleScale) < 1e-9)
    }

    // MARK: Letter wave

    @Test("Every letter floats, in reading order")
    func lettersFloatInOrder() {
        let word = Self.word(durationMs: 400, startMs: 0)
        let waves = RichLyricsAnimation.letterWaves(for: word, letterCount: 4, timing: Self.timing)

        #expect(waves.count == 4)
        #expect(waves[0].startMs <= 0.001, "the first letter did not start with its word")
        for index in 1 ..< waves.count {
            #expect(waves[index].startMs >= waves[index - 1].startMs, "letter \(index) started before the one before it")
        }
        #expect(RichLyricsAnimation.letterWaves(for: word, letterCount: 0, timing: Self.timing).isEmpty)
    }

    @Test("A letter crests when the swipe has finished lighting it")
    func letterCrestsWhenLit() {
        let word = Self.word(durationMs: 700, startMs: 0)
        let count = 5
        let waves = RichLyricsAnimation.letterWaves(for: word, letterCount: count, timing: Self.timing)

        for index in 0 ..< count {
            let crest = waves[index].startMs + waves[index].durationMs * Self.timing.letterWaveCrestOffset
            let lit = Self.litTime(of: index, of: count, word: word)
            #expect(abs(crest - lit) < 0.001, "letter \(index) crested at \(crest) ms but was lit at \(lit) ms")
        }
    }

    @Test("A held word stretches its letters' floats instead of letting them settle early")
    func heldWordStretchesItsWave() {
        let short = Self.word(durationMs: 400, startMs: 0)
        let long = Self.word(durationMs: 2_400, startMs: 0)

        let shortWave = RichLyricsAnimation.letterWaves(for: short, letterCount: 2, timing: Self.timing)[1]
        let longWave = RichLyricsAnimation.letterWaves(for: long, letterCount: 2, timing: Self.timing)[1]

        #expect(
            longWave.durationMs > shortWave.durationMs,
            "a held word's float lasted \(longWave.durationMs) ms against a short word's \(shortWave.durationMs) ms"
        )
    }

    @Test("A letter rises to its crest and comes back most of the way")
    func letterFloatRisesAndSettles() {
        let word = Self.word(durationMs: 400, startMs: 0)
        let wave = RichLyricsAnimation.letterWaves(for: word, letterCount: 1, timing: Self.timing)[0]
        let timing = Self.timing

        #expect(
            RichLyricsAnimation.letterFloat(of: wave, word: word, at: wave.startMs - 1, timing: timing) == .rest
        )

        let crestTime = wave.startMs + wave.durationMs * timing.letterWaveCrestOffset
        let crest = RichLyricsAnimation.letterFloat(of: wave, word: word, at: crestTime, timing: timing)
        #expect(abs(crest.liftEm - timing.letterWaveLiftEm) < 1e-9, "the crest lifted \(crest.liftEm) em")
        #expect(crest.scale == 1, "a short word's letter scaled")

        // Once its float is over — and while the word is still being sung — a letter rests just
        // above the baseline; the word drops the rest of the way when it has finished.
        let resting = RichLyricsAnimation.letterFloat(
            of: wave,
            word: word,
            at: wave.startMs + wave.durationMs + 1,
            timing: timing
        )
        #expect(abs(resting.liftEm - timing.letterWaveSettleEm) < 1e-9)
        #expect(resting.scale == 1)

        // And it holds that rest for as long as the line is being sung: Better Lyrics leaves the
        // finished float in place rather than easing the letter all the way down.
        let settled = RichLyricsAnimation.letterFloat(
            of: wave,
            word: word,
            at: wave.startMs + wave.durationMs + 500,
            timing: timing
        )
        #expect(abs(settled.liftEm - timing.letterWaveSettleEm) < 1e-9)
    }

    @Test("A long word swells each letter at its crest, a short one does not")
    func longWordsSwellTheirLetters() {
        let long = Self.word(durationMs: Self.timing.longWordThresholdMs, startMs: 0)
        let wave = RichLyricsAnimation.letterWaves(for: long, letterCount: 1, timing: Self.timing)[0]
        let crestTime = wave.startMs + wave.durationMs * Self.timing.letterWaveCrestOffset

        let crest = RichLyricsAnimation.letterFloat(of: wave, word: long, at: crestTime, timing: Self.timing)
        #expect(
            abs(crest.scale - Self.timing.longWordScale) < 1e-6,
            "a held word's letter crested at \(crest.scale) instead of \(Self.timing.longWordScale)"
        )

        let short = Self.word(durationMs: Self.timing.longWordThresholdMs - 1, startMs: 0)
        let shortWave = RichLyricsAnimation.letterWaves(for: short, letterCount: 1, timing: Self.timing)[0]
        let shortCrestTime = shortWave.startMs + shortWave.durationMs * Self.timing.letterWaveCrestOffset
        let shortCrest = RichLyricsAnimation.letterFloat(of: shortWave, word: short, at: shortCrestTime, timing: Self.timing)
        #expect(abs(shortCrest.liftEm - Self.timing.letterWaveLiftEm) < 1e-9)
        #expect(shortCrest.scale == 1, "a word under the threshold swelled as if it were held")
    }

    // MARK: Glow

    @Test("The bloom outlives its word and is quiet at both ends")
    func glowSettlesAfterTheWord() {
        let word = Self.word(durationMs: 100, startMs: 0)
        let timing = Self.timing

        #expect(RichLyricsAnimation.glow(for: word, at: 0, timing: timing) == 0)
        #expect(RichLyricsAnimation.glow(for: word, at: -100, timing: timing) == 0)

        // A word too short for its own glow still blooms for the floor's length.
        #expect(RichLyricsAnimation.glow(for: word, at: 600, timing: timing) > 0)
        #expect(RichLyricsAnimation.glow(for: word, at: 1_100, timing: timing) > 0)
        #expect(RichLyricsAnimation.glow(for: word, at: 1_200, timing: timing) == 0)

        // And it only ever calms.
        var previous = RichLyricsAnimation.glow(for: word, at: 1, timing: timing)
        for step in 1 ... 40 {
            let glow = RichLyricsAnimation.glow(for: word, at: Double(step) * 30, timing: timing)
            #expect(glow <= previous + 1e-9, "the bloom brightened at \(step * 30) ms")
            previous = glow
        }
    }

    // MARK: Line-synced

    @Test("A line-synced lyric fades in over a third of a second")
    func lineSyncedFadesIn() {
        let word = Self.word(durationMs: 4_000, startMs: 0)
        let timing = Self.timing

        #expect(RichLyricsAnimation.lineFadeIn(for: word, at: -1, timing: timing) == 0)
        #expect(abs(RichLyricsAnimation.lineFadeIn(for: word, at: timing.lineFadeInMs, timing: timing) - 1) < 1e-9)
        let middle = RichLyricsAnimation.lineFadeIn(for: word, at: timing.lineFadeInMs / 2, timing: timing)
        #expect(middle > 0.4 && middle < 0.9, "the fade was \(middle) half way through")
    }

    // MARK: Static frames

    @Test("A word nothing can move on any more is handed one constant position")
    func settledWordIsFrozen() {
        let word = Self.word(durationMs: 140, startMs: 1_000)
        let waves = RichLyricsAnimation.letterWaves(for: word, letterCount: 2, timing: Self.timing)
        let frozen = RichLyricsAnimation.settledTimeMs(for: word, waves: waves, timing: Self.timing)

        // At that position the word is exactly what it stays: fully lit, at rest, unglowing, every
        // letter at its settled rest.
        let later = frozen + 5_000
        #expect(RichLyricsAnimation.band(for: word, at: frozen, timing: Self.timing) == RichLyricsAnimation.band(for: word, at: later, timing: Self.timing))
        #expect(RichLyricsAnimation.band(for: word, at: frozen, timing: Self.timing).isFullyLit)
        #expect(RichLyricsAnimation.wobble(for: word, at: frozen, timing: Self.timing) == .identity)
        #expect(RichLyricsAnimation.glow(for: word, at: frozen, timing: Self.timing) == 0)
        for wave in waves {
            #expect(
                RichLyricsAnimation.letterFloat(of: wave, word: word, at: frozen, timing: Self.timing)
                    == RichLyricsAnimation.letterFloat(of: wave, word: word, at: later, timing: Self.timing)
            )
        }

        // So the renderer is handed that constant from then on, never the clock …
        #expect(RichLyricsAnimation.renderTimeMs(for: word, waves: waves, at: frozen, timing: Self.timing) == frozen)
        #expect(RichLyricsAnimation.renderTimeMs(for: word, waves: waves, at: frozen + 400, timing: Self.timing) == frozen)

        // While any part of the word is still moving — before it is sung, and after it is sung
        // while its bloom and floats are still running — it is the clock that is passed through.
        #expect(RichLyricsAnimation.renderTimeMs(for: word, waves: waves, at: 0, timing: Self.timing) == 0)
        #expect(RichLyricsAnimation.renderTimeMs(for: word, waves: waves, at: 1_100, timing: Self.timing) == 1_100)
    }

    @Test("Letters a fraction of a point apart share one layer")
    func closeLettersShareALayer() {
        let rest = RichLyricsLetterFloat.rest
        // At 16 pt the threshold is a quarter of a point, so 0.015 em is inside it and 0.05 em is
        // not.
        let withinReach = RichLyricsLetterFloat(liftEm: 0.015, scale: 1)
        let shared = RichLyricsAnimation.sharedFloat(of: [rest, withinReach], fontSize: 16)
        #expect(shared != nil)
        #expect(
            abs((shared?.liftEm ?? -1) - 0.0075) < 1e-9,
            "the shared word sat at \(shared?.liftEm ?? -1) instead of in the middle of its letters"
        )

        // A wave that can be seen keeps its layer per letter.
        let apart = RichLyricsLetterFloat(liftEm: 0.05, scale: 1)
        #expect(RichLyricsAnimation.sharedFloat(of: [rest, apart], fontSize: 16) == nil)

        // A one-letter word, and a word whose letters are level, are one layer either way.
        #expect(RichLyricsAnimation.sharedFloat(of: [rest], fontSize: 16) == rest)
        #expect(RichLyricsAnimation.sharedFloat(of: [rest, rest], fontSize: 16) == rest)
        #expect(RichLyricsAnimation.sharedFloat(of: [], fontSize: 16) == nil)

        // A shared layer only rises. Scaling one layer would widen the whole word about its centre
        // and carry every glyph sideways with it, which is exactly the sideways movement the reader
        // switched off — so a collapsed word keeps its width however far its letters have swelled.
        let longWordCrest = RichLyricsLetterFloat(
            liftEm: 0.015,
            scale: RichLyricsTiming.standard.longWordScale - 0.005
        )
        let collapsed = RichLyricsAnimation.sharedFloat(of: [longWordCrest, longWordCrest], fontSize: 16)
        #expect(collapsed?.scale == 1, "a shared layer was scaled to \(collapsed?.scale ?? -1)")
        #expect(abs((collapsed?.liftEm ?? 0) - 0.015) < 1e-9)
    }

    @Test("A syllable-timed line stops redrawing the words that have finished")
    func denseLineFreezesSungWords() {
        // A duet arrives timed per syllable: twenty-four units, none of them sung for more than a
        // fifth of a second, so their blooms and floats outlast them several times over.
        let units = 24
        let words = (0 ..< units).map { index in
            KaraokeWord(
                index: index,
                text: "la",
                isNewWord: index % 2 == 0,
                fillStartMs: Double(index) * 140,
                fillEndMs: Double(index) * 140 + 120
            )
        }
        let waves = words.map { RichLyricsAnimation.letterWaves(for: $0, letterCount: 2, timing: Self.timing) }
        func liveWords(at timeMs: Double) -> Int {
            words.indices.count { index in
                RichLyricsAnimation.renderTimeMs(for: words[index], waves: waves[index], at: timeMs, timing: Self.timing) == timeMs
            }
        }

        // A third of the way in, the syllables behind that point that have also finished their
        // bloom and their floats are handed one constant position.
        #expect(liveWords(at: 1_600) < units)
        // Once the line's last bloom is out, every word of it is: the line is one picture from there
        // on, however many units it carries.
        #expect(liveWords(at: 4_600) == 0)
    }

    // MARK: Curves

    @Test("The curves are the CSS ones they are named after")
    func curvesMatchCSS() {
        for curve: RichLyricsCurve in [.linear, .ease, .easeInOut, .easeOut] {
            #expect(curve.value(at: 0) == 0)
            #expect(curve.value(at: 1) == 1)
            #expect(curve.value(at: -1) == 0)
            #expect(curve.value(at: 2) == 1)

            var previous = 0.0
            for step in 0 ... 100 {
                let value = curve.value(at: Double(step) / 100)
                #expect(value >= previous - 1e-9, "the curve went backwards at \(step)%")
                previous = value
            }
        }

        // `ease` is what gives the bloom its quick fall and the wobble its soft start.
        #expect(abs(RichLyricsCurve.ease.value(at: 0.5) - 0.8024) < 0.005)
        #expect(RichLyricsCurve.easeInOut.value(at: 0.5) == 0.5)
    }
}
