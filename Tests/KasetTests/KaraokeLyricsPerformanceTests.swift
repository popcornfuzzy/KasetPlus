import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Kaset

/// Measures what the karaoke animation costs while a song plays, so it can be made cheaper
/// without changing how it looks.
///
/// Each iteration builds and renders the line at a new display position, which is what a
/// `TimelineView` frame does: body evaluation, layout, masking, halo blur and text draw.
/// Absolute numbers are pessimistic — rasterizing into a bitmap is CPU work the app does on
/// the GPU — so the *report* is the useful part: it attributes the cost to the layout, the halo
/// and the fill machinery, and states the total as a share of one CPU core at each row's own
/// redraw rate.
///
/// Because of that, structure is asserted as **ratios** measured in the same run, not as an
/// absolute time: one GitHub runner priced every scenario about 1.6× higher than a laptop, all of
/// them together, which says the machine is slower and nothing about the row.
@MainActor
@Suite(.tags(.model, .slow))
struct KaraokeLyricsPerformanceTests {
    /// Ceiling for one frame of one line, and a coarse one: it catches a row that has become
    /// catastrophically expensive, not one that has drifted. The slowest machine this suite has run on
    /// (a GitHub runner) priced a syllable-timed duet frame at 8.17 ms against 5.17 ms on a laptop, with
    /// every other scenario scaled the same way; structure is the ratios below.
    private static let catastrophicMsPerFrame = 12.0

    /// What the Better Lyrics decorations may add to the same line drawn with the plain sweep.
    /// Measured between 1.43× and 1.90× across machines and loads, with one 2.27× reading on a runner
    /// before the pair was measured inside the same pass — the limit is set well above the honest cost
    /// because it is there to catch the decorations becoming something else, not to police a few percent.
    private static let decoratedOverSweep = 2.6

    /// What timing a duet line per syllable may add over timing it per word: three times the units, and
    /// the per-letter wave across them. Measured 1.63× on a laptop and 1.86× on the runner.
    private static let syllableTimingOverWordTiming = 2.5

    private struct Scenario {
        let name: String
        let line: SyncedLyricLine
        let fontSize: CGFloat
        let width: CGFloat
        /// Milliseconds the frames span, so the run crosses several word boundaries.
        let spanMs: Double
        /// Decoration strength the surface this scenario stands for actually carries, so the harness
        /// prices the frame the app asks for rather than a heavier one it never draws: the lyrics
        /// panel passes 0.55 and the fullscreen player 1.0 (`SyncedLyricsDisplayView.emphasis`,
        /// `FullscreenNowPlayingView.karaokeEmphasis`).
        var emphasis: Double = 1
        /// Playback position of the first frame.
        var startMs: Double = 1000
        /// How often this row redraws in the app.
        let framesPerSecond: Double
        /// Which word animation the row is drawn with.
        var style: LyricsAnimationStyle = .appleMusic
        /// Whether the row is the other singer's, drawn against the trailing edge.
        var isTrailingAligned: Bool = false

        /// Name the structural checks below find this measurement by.
        var key: String = ""
    }

    /// The decoration strength the lyrics panel and the sidebar's sheets carry.
    private static let panelEmphasis = 0.55

    @Test("Live karaoke frames stay within budget")
    func liveFrameCost() throws {
        let timings = (0 ..< 8).map { index in
            TimedWord(timeInMs: index * 420, word: index == 0 ? "Sing" : " word\(index)")
        }
        let wordTimed = SyncedLyricLine(
            timeInMs: 0,
            duration: 3600,
            text: "Sing word1 word2 word3 word4 word5 word6 word7",
            words: timings
        )
        let lineSynced = SyncedLyricLine(
            timeInMs: 0,
            duration: 3600,
            text: "Sing word1 word2 word3 word4 word5 word6 word7",
            words: nil
        )
        // A duet line as Apple's word-synced TTML writes one: timed per syllable, so it carries
        // many more units than a line timed per word, and the row against the trailing edge.
        let duetTimings = (0 ..< 24).map { index in
            TimedWord(timeInMs: index * 140, word: index == 0 ? "I" : " la")
        }
        let duetLine = SyncedLyricLine(
            timeInMs: 0,
            duration: 3600,
            text: "I la la la la la la la la la la la la la la la la la la la la la la la",
            words: duetTimings,
            isOppositeTurn: true
        )
        let duetTimed = SyncedLyricLine(
            timeInMs: 0,
            duration: 3600,
            text: wordTimed.text,
            words: timings,
            isOppositeTurn: true
        )

        let live = 1 / KaraokeFrameBudget.live
        let armed = 1 / KaraokeFrameBudget.armed

        let scenarios = [
            Scenario(name: "panel, current line, word-by-word   ", line: wordTimed, fontSize: 16, width: 248, spanMs: 1200, emphasis: Self.panelEmphasis, framesPerSecond: live, key: "panelWordTimed"),
            Scenario(name: "panel, current line, better lyrics   ", line: wordTimed, fontSize: 16, width: 248, spanMs: 1200, emphasis: Self.panelEmphasis, framesPerSecond: live, style: .betterLyrics, key: "panelBetterLyrics"),
            Scenario(name: "panel, current line, line-by-line    ", line: lineSynced, fontSize: 16, width: 248, spanMs: 1200, emphasis: Self.panelEmphasis, framesPerSecond: live),
            Scenario(name: "fullscreen, current line, word-by-word", line: wordTimed, fontSize: 36, width: 600, spanMs: 1200, framesPerSecond: live, key: "fullscreenWordTimed"),
            Scenario(name: "fullscreen, current line, better lyrics", line: wordTimed, fontSize: 36, width: 600, spanMs: 1200, framesPerSecond: live, style: .betterLyrics, key: "fullscreenBetterLyrics"),
            Scenario(name: "panel, current line, duet (sung)        ", line: duetTimed, fontSize: 16, width: 248, spanMs: 1200, emphasis: Self.panelEmphasis, framesPerSecond: live, style: .betterLyrics, isTrailingAligned: true, key: "panelDuetWordTimed"),
            Scenario(name: "panel, current line, duet syllables     ", line: duetLine, fontSize: 16, width: 248, spanMs: 1200, emphasis: Self.panelEmphasis, framesPerSecond: live, style: .betterLyrics, isTrailingAligned: true, key: "panelDuetSyllables"),
            Scenario(name: "fullscreen, duet (sung)             ", line: duetTimed, fontSize: 36, width: 600, spanMs: 1200, framesPerSecond: live, style: .betterLyrics, isTrailingAligned: true, key: "fullscreenDuetWordTimed"),
            Scenario(name: "fullscreen, duet syllables          ", line: duetLine, fontSize: 36, width: 600, spanMs: 1200, framesPerSecond: live, style: .betterLyrics, isTrailingAligned: true, key: "fullscreenDuetSyllables"),
            Scenario(name: "fullscreen, current line, line-by-line ", line: lineSynced, fontSize: 36, width: 600, spanMs: 1200, framesPerSecond: live),
            // The line after the current one also redraws, on the same clock, so it is part
            // of the bill. Nothing on it moves until it becomes the current line.
            Scenario(name: "panel, next line (armed, untouched)  ", line: wordTimed, fontSize: 16, width: 248, spanMs: 0, emphasis: Self.panelEmphasis, startMs: -800, framesPerSecond: armed),
            Scenario(name: "panel, next line (armed, better lyrics)", line: wordTimed, fontSize: 16, width: 248, spanMs: 0, emphasis: Self.panelEmphasis, startMs: -800, framesPerSecond: armed, style: .betterLyrics),
            Scenario(name: "fullscreen, next line (armed)        ", line: wordTimed, fontSize: 36, width: 600, spanMs: 0, startMs: -800, framesPerSecond: armed),
            Scenario(name: "fullscreen, next line (armed, better lyrics)", line: wordTimed, fontSize: 36, width: 600, spanMs: 0, startMs: -800, framesPerSecond: armed, style: .betterLyrics),
        ]

        var report: [String] = []
        var regressions: [String] = []
        var panelShare = 0.0
        var fullscreenShare = 0.0

        // Three passes over the whole table, each scenario once per pass.
        //
        // The passes are what makes a structural ratio mean anything on a shared machine: two scenarios
        // priced against each other are measured seconds apart, inside the same pass, so a runner that is
        // slow for one of them is slow for both. A single pass per scenario — the shape this harness had
        // first — let one side of a pair be interrupted and the other not, which is how a clip that had not
        // changed once measured 2.27× against a 2.2× limit on CI.
        var passCosts: [[Double]] = []
        for _ in 0 ..< 3 {
            var pass: [Double] = []
            pass.reserveCapacity(scenarios.count)
            for scenario in scenarios {
                pass.append(self.liveFrames(scenario, rounds: 1))
            }
            passCosts.append(pass)
        }
        // Each scenario's cheapest pass: contention only ever adds time.
        let costs = scenarios.indices.map { index in
            passCosts.map { $0[index] }.min() ?? .infinity
        }
        let indexByKey = Dictionary(
            uniqueKeysWithValues: scenarios.enumerated().compactMap { index, scenario in
                scenario.key.isEmpty ? nil : (scenario.key, index)
            }
        )

        for (index, scenario) in scenarios.enumerated() {
            let perFrame = costs[index]
            let perSecond = perFrame * scenario.framesPerSecond
            if scenario.name.hasPrefix("panel") {
                panelShare += perSecond
            } else {
                fullscreenShare += perSecond
            }
            // Milliseconds of drawing per second of playback, as a share of one core:
            // 1000 ms/s is a whole core, so 100 ms/s is 10%.
            report.append(
                "\(scenario.name): \(Self.format(perFrame)) ms/frame at \(Int(scenario.framesPerSecond)) fps = \(Self.format(perSecond / 10))% of a core"
            )
            if perFrame > Self.catastrophicMsPerFrame {
                regressions.append(
                    "\(scenario.name): \(Self.format(perFrame)) ms/frame exceeds the \(Self.format(Self.catastrophicMsPerFrame)) ms ceiling"
                )
            }
        }

        // Structure, priced against the machine the run is on: the same machine draws both sides of each
        // ratio, so the ratio is the row's own cost and not the CPU's. Measured per pass and then taken as
        // the median of the three, so a pass where one side was interrupted cannot decide it.
        func ratio(_ numerator: String, _ denominator: String) -> Double? {
            guard let numeratorIndex = indexByKey[numerator], let denominatorIndex = indexByKey[denominator] else {
                return nil
            }
            let ratios = passCosts.compactMap { pass -> Double? in
                let denominatorMs = pass[denominatorIndex]
                guard denominatorMs > 0 else { return nil }
                return pass[numeratorIndex] / denominatorMs
            }
            guard !ratios.isEmpty else { return nil }
            return ratios.sorted()[ratios.count / 2]
        }

        let structuralChecks: [(name: String, measured: Double?, limit: Double)] = [
            (
                "panel, Better Lyrics decorations against the plain sweep",
                ratio("panelBetterLyrics", "panelWordTimed"),
                Self.decoratedOverSweep
            ),
            (
                "fullscreen, Better Lyrics decorations against the plain sweep",
                ratio("fullscreenBetterLyrics", "fullscreenWordTimed"),
                Self.decoratedOverSweep
            ),
            (
                "panel, duet timed per syllable against timed per word",
                ratio("panelDuetSyllables", "panelDuetWordTimed"),
                Self.syllableTimingOverWordTiming
            ),
            (
                "fullscreen, duet timed per syllable against timed per word",
                ratio("fullscreenDuetSyllables", "fullscreenDuetWordTimed"),
                Self.syllableTimingOverWordTiming
            ),
        ]

        for check in structuralChecks {
            guard let measured = check.measured else { continue }
            report.append(
                "structural — \(check.name): \(Self.format(measured))× (limit \(Self.format(check.limit))×)"
            )
            if measured > check.limit {
                regressions.append(
                    "\(check.name): \(Self.format(measured))× exceeds the \(Self.format(check.limit))× limit"
                )
            }
        }

        // Attribution on the expensive path: what the layout hoist and the halo are worth.
        let wordScenario = scenarios[0]
        let rebuilt = self.liveFrames(wordScenario, rebuildLayout: true)
        let undecorated = self.liveFrames(wordScenario, emphasis: 0)
        let lifted = self.liveFrames(wordScenario, emphasis: 1)
        report.append(
            "attribution — panel word-by-word, layout rebuilt per frame: \(Self.format(rebuilt)) ms/frame"
        )
        report.append(
            "attribution — panel word-by-word, no halo/feather/swell: \(Self.format(undecorated)) ms/frame"
        )
        // And what the lift is worth on the same line: at the panel's own emphasis it is under a
        // quarter point of travel, so it is not drawn at all — this prices the same line at the
        // strength that does draw it.
        report.append(
            "attribution — panel word-by-word, lift drawn (emphasis 1): \(Self.format(lifted)) ms/frame"
        )

        // What a syllable-dense line is paying for. A duet is written per syllable, so it carries
        // three times the units of a word-timed line; these split that extra cost into the units
        // themselves (drawn in the plain sweep style), the Better Lyrics decorations (drawn with the
        // decorations off), and the bloom alone — which is what showed that the per-letter wave, not
        // the halo, was the decoration a syllable-timed line was paying for.
        if let duetScenario = scenarios.first(where: { $0.name.contains("duet syllables") }) {
            let duetPlain = self.liveFrames(duetScenario, emphasis: 0)
            let duetSweep = self.liveFrames(duetScenario, style: .appleMusic)
            var noGlow = RichLyricsTiming.standard
            noGlow.glowOpacity = 0
            let duetNoBloom = self.liveFrames(duetScenario, timing: noGlow)
            report.append(
                "attribution — duet syllables, decorations off: \(Self.format(duetPlain)) ms/frame"
            )
            report.append(
                "attribution — duet syllables, plain sweep: \(Self.format(duetSweep)) ms/frame"
            )
            report.append(
                "attribution — duet syllables, no bloom: \(Self.format(duetNoBloom)) ms/frame"
            )
        }

        // The pause row's dots. What is being drawn when the highlight is on a pause row is three
        // dots and a bounce; what was being *computed* was the question of when the silence began,
        // which is measured from the line above the row (`KaraokeFillModel.settleBoundaryMs`) — asked
        // on every frame of the bounce. The row holds one interlude and asks it for each frame's dots,
        // and this prices both ends of that.
        let dots = Self.pauseDotFrameCosts(lyrics: Self.pauseDotsSheet())
        report.append(
            "pause dots, interlude resolved once: \(Self.format(dots.resolved, places: 3)) ms/frame against \(Self.format(dots.perFrame, places: 3)) re-derived per frame"
        )

        // A worst case that would be unacceptable as an animation budget in the harness's
        // pessimistic terms: one core just for lyrics.
        //
        // The panel and the fullscreen player are the two surfaces that animate, and their sheets can
        // no longer animate **together**: presenting the player covers every other lyric sheet, and a
        // covered sheet draws no frames at all (`KaraokeFrameBudget.plan`) — the sidebar behind the
        // player used to keep singing at the full live rate. So the bill is the worse of the two, not
        // their sum, which is printed underneath for reference.
        report.append("worst case, one surface animating: \(Self.format(max(panelShare, fullscreenShare) / 10))% of a core")
        report.append("for reference, both surfaces summed (they cannot run together): \(Self.format((panelShare + fullscreenShare) / 10))% of a core")

        // The report is attached to a failure, so a regression arrives with the numbers
        // that explain it. `KARAOKE_PERF_REPORT=1 swift test --filter KaraokeLyricsPerformanceTests`
        // prints the numbers on a healthy run too (as a deliberately failing issue).
        let wantsReport = ProcessInfo.processInfo.environment["KARAOKE_PERF_REPORT"] == "1"
        if !regressions.isEmpty || wantsReport {
            let header = regressions.isEmpty ? "Karaoke frame cost:" : "Karaoke frame cost regressed:"
            Issue.record(
                Comment(rawValue: header + "\n" + (regressions + [""] + report).joined(separator: "\n"))
            )
        }
    }

    /// What the sheet pays to know when its lines change.
    ///
    /// The schedule is built when the sheet is constructed — once per re-render of the sheet, which
    /// happens on every playback sample — and only searched while playback runs. Building it is only
    /// the right shape if a build is far cheaper than a frame, so it is measured against one.
    @Test("The line schedule costs far less than a frame")
    func lineScheduleCost() throws {
        // A duet sheet as Apple Music writes it: 60 paragraphs, each timed per syllable, alternating
        // singers.
        let lines = (0 ..< 60).map { index -> SyncedLyricLine in
            let start = index * 2_000
            let words = (0 ..< 24).map { unit in
                TimedWord(timeInMs: start + unit * 70, word: unit == 0 ? "I" : " la")
            }
            return SyncedLyricLine(
                timeInMs: start,
                duration: 1_800,
                text: Array(repeating: "la", count: 23).joined(separator: " ") + " la",
                words: words,
                isOppositeTurn: index % 2 == 1
            )
        }
        let lyrics = SyncedLyrics(lines: lines, source: "KaraokePerf")

        for _ in 0 ..< 3 { _ = KaraokeFillModel.lineChanges(in: lyrics) }
        let runs = 20
        var changes: [KaraokeLineChange] = []
        let started = DispatchTime.now()
        for _ in 0 ..< runs { changes = KaraokeFillModel.lineChanges(in: lyrics) }
        let perBuildMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000 / Double(runs)

        // Searching it, which is what every playback sample and every wake-up does.
        let searchStarted = DispatchTime.now()
        for step in 0 ..< 600 {
            let position = Double(step) * 200
            _ = KaraokeFillModel.highlightIndex(in: changes, at: position)
            _ = KaraokeFillModel.scrollIndex(in: changes, at: position)
            _ = KaraokeFillModel.nextChangeMs(in: changes, after: position)
        }
        let perSearchUs = Double(DispatchTime.now().uptimeNanoseconds - searchStarted.uptimeNanoseconds) / 1_000 / 1_800

        let report = "line schedule: \(Self.format(perBuildMs, places: 3)) ms per build of \(changes.count) lines, \(Self.format(perSearchUs, places: 2)) µs per search"
        if ProcessInfo.processInfo.environment["KARAOKE_PERF_REPORT"] == "1" {
            Issue.record(Comment(rawValue: report))
        }
        // Building it runs once per re-render of the sheet, so the budget is a fraction of a frame;
        // searching it runs on every playback sample and every wake-up.
        #expect(perBuildMs < 2, Comment(rawValue: report))
        #expect(perSearchUs < 60, Comment(rawValue: report))
    }

    /// The cost of one display frame of the wipe, at one playback position after another.
    /// The layout is built once, the way the row builds it from its cache.
    private func liveFrames(
        _ scenario: Scenario,
        rounds: Int = 3,
        rebuildLayout: Bool = false,
        emphasis: Double? = nil,
        style: LyricsAnimationStyle? = nil,
        timing: RichLyricsTiming = .standard
    ) -> Double {
        let frames = 60
        let emphasis = emphasis ?? scenario.emphasis
        let style = style ?? scenario.style
        let layout = KaraokeLineLayout(line: scenario.line, fontSize: scenario.fontSize)

        // Warm up so first-frame setup (font caches, layout) is not measured.
        for index in 0 ..< 5 {
            self.render(scenario, layout: layout, at: scenario.startMs + Double(index) * 16, emphasis: emphasis, style: style, timing: timing)
        }

        // The cheapest of a few rounds, not the first one.
        //
        // A frame's cost is one-sided noise: a busy machine adds time to a measurement and never removes
        // it, and this harness shares its process with every other test in the suite, which Swift Testing
        // runs in parallel. A single round therefore sometimes priced the contention rather than the row,
        // and the budget failed on tests that had not changed. The cheapest round is the frame's cost.
        var best = Double.infinity
        for _ in 0 ..< max(1, rounds) {
            let started = DispatchTime.now()
            for index in 0 ..< frames {
                let ms = scenario.startMs + scenario.spanMs * Double(index) / Double(frames)
                let frameLayout = rebuildLayout
                    ? KaraokeLineLayout(line: scenario.line, fontSize: scenario.fontSize)
                    : layout
                self.render(scenario, layout: frameLayout, at: ms, emphasis: emphasis, style: style, timing: timing)
            }
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            best = min(best, elapsedMs / Double(frames))
        }
        return best
    }

    private func render(
        _ scenario: Scenario,
        layout: KaraokeLineLayout,
        at displayTimeMs: Double,
        emphasis: Double,
        style: LyricsAnimationStyle,
        timing: RichLyricsTiming = .standard
    ) {
        let view = KaraokeLyricsLineView(
            layout: layout,
            displayTimeMs: displayTimeMs,
            emphasis: emphasis,
            style: style,
            richTiming: timing,
            isTrailingAligned: scenario.isTrailingAligned
        )
        .frame(width: scenario.width, height: scenario.fontSize * 4, alignment: .topLeading)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        _ = renderer.cgImage
    }

    /// A sheet with a sung line and the pause that follows it, so a pause row has an interlude to
    /// show: nine lead words, so the line above has words to measure.
    private static func pauseDotsSheet() -> SyncedLyrics {
        SyncedLyrics(
            lines: [
                SyncedLyricLine(
                    timeInMs: 0,
                    duration: 4000,
                    text: "one two three four five six seven eight nine",
                    words: (0 ..< 9).map { index in
                        TimedWord(timeInMs: index * 430, word: index == 0 ? "one" : " word\(index)")
                    }
                ),
                SyncedLyricLine(timeInMs: 4000, duration: 6000, text: "", words: nil),
            ],
            source: "KaraokePauseDotsHarness"
        )
    }

    /// The cost of one frame of a pause row's dots, both ways: the interlude resolved once for the row
    /// (what the row does now) and re-derived from the line above on every frame (what it did).
    private static func pauseDotFrameCosts(lyrics: SyncedLyrics) -> (resolved: Double, perFrame: Double) {
        let frames = 600
        func positions(_ body: (Int) -> Void) -> Double {
            for index in 0 ..< 50 { body(index) }
            let started = DispatchTime.now()
            for index in 0 ..< frames { body(index) }
            return Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000 / Double(frames)
        }

        let perFrame = positions { index in
            _ = lyrics.pauseDots(forLineAt: 1, at: 4200 + index * 10)
        }
        let interlude = lyrics.pauseInterlude(forLineAt: 1)
        let resolved = positions { index in
            _ = SyncedLyrics.PauseDots(interlude: interlude, at: 4200 + index * 10)
        }
        return (resolved, perFrame)
    }

    private static func format(_ value: Double, places: Int = 2) -> String {
        String(format: "%.\(places)f", value)
    }
}
