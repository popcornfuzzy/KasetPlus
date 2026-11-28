import AppKit
import SwiftUI
import Testing
@testable import Kaset

/// The line the sheet travels past must leave *with* the scroll — even while it is still filling — and
/// leave smoothly.
///
/// Three defects lived here. The highlight used to be taken from the **scroll** lead — the panel fed
/// `currentLineIndex(at: timeMs + 120)` into the rows' status — so a line began to
/// dim, shrink and recede 120 ms before its last word had finished filling: it never reached its
/// sung state before it started to leave, which is what "it doesn't animate smoothly into the sung
/// state" was. And the row kept redrawing that frozen frame, inside a changing scale, until a
/// trailing window expired. The third is the one this file now pins from the other side: once the
/// highlight was taken off the scroll lead the sung row kept its full size and brightness until the
/// baton, half a second *after* the sheet had travelled — so the sheet moved, the old line sat at full
/// size, and then shrank on an animation of its own, which reads as an interruption. The emphasis is
/// anchored on the scroll (`LyricLineEmphasis.emphasis`), so the departure begins with the page.
///
/// Nothing offscreen can observe an implicit animation or a redraw — `ImageRenderer` draws one frame
/// at model values and never runs a timeline — so this hosts the **real** panel in a window,
/// publishes playback samples at the 10 Hz the WebView's lyrics poll reports at, and reads the
/// rendered pixels between them. The line that leaves is given a deliberately wide text, so its right
/// edge is the widest ink on screen and can be followed frame by frame: a spring shows as a series of
/// intermediate widths, a snap as one. Its last word fills late, so how far the bright part of that
/// row reaches across it says whether the line was still being sung as it left — which, leaving with
/// the scroll, it is.
///
/// **Sampling floor.** Reading a frame out of a hosted `NSView` costs ~60 ms on this machine (AppKit's
/// offscreen caching path, not the drawing), so the trace runs at roughly 15 Hz however tightly the
/// loop is written. The departure assertions below are shaped for that: they ask that the change takes
/// several *sampled* frames to arrive and that no single sample carries most of it, which a change
/// applied in one step cannot satisfy, rather than pretending to follow a 0.42 s spring at 60 Hz.
@MainActor
@Suite(.tags(.model))
struct LyricsEmphasisAnimationTests {
    /// Advances the run loop for the given wall-clock time, so the hosted view actually renders
    /// frames instead of jumping straight to the end state.
    private func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
    }

    // MARK: - Recording

    /// One frame of the hosted panel, in device pixels.
    private struct TracedFrame {
        /// The playback position the panel had been handed for this frame.
        let timeMs: Int
        /// Wall-clock milliseconds since the sheet was told to travel, or `0` before it was.
        let elapsedMs: Double
        /// Left-most and right-most inked columns of the whole sheet.
        let minX: Int
        let maxX: Int
        /// Brightest ink on the sheet. A row being sung is drawn at full opacity, and the falloff
        /// takes it to `focusedOpacity`-and-below on the frame the sheet travels — so this is the
        /// row's own fade, read in alpha.
        let peak: Int
        /// How far the bright (sung) part of the sheet's widest row reaches across that row, 0...1.
        /// A row that is still being sung has a dim run at its right where the fill has not got to.
        let sungReach: Double
    }

    /// What a departure looked like, frame by frame.
    private struct DepartureTrace {
        let frames: [TracedFrame]
        /// When the sheet starts travelling away from the line under test.
        let leadStartMs: Int
        /// When the line below takes the baton.
        let batonMs: Int
        /// Right-most inked column before the sheet started travelling, while the line under test was
        /// still in the anchor at its sung size.
        let fullWidth: Int
        /// Brightest ink before the sheet started travelling: the row under test at full opacity.
        let fullPeak: Int
        /// The first frame whose line had begun to shrink, if it began at all.
        let departureIndex: Int?

        /// The last frame of the scroll lead: recorded while the sheet was travelling, before the
        /// baton was ever published for the line below.
        var endOfLead: TracedFrame? {
            self.frames.last { $0.timeMs >= self.leadStartMs }
        }
    }

    /// Records a frame while the run loop is pumped for `seconds`.
    private func record(_ view: NSView, at timeMs: Int, for seconds: Double, since start: Date? = nil) -> [TracedFrame] {
        var frames: [TracedFrame] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
            let elapsed = start.map { Date().timeIntervalSince($0) * 1000 } ?? 0
            if let frame = Self.capture(view, at: timeMs, elapsedMs: elapsed) {
                frames.append(frame)
            }
        }
        return frames
    }

    /// The panel's pixels, reduced to what the departure moves: the extent of the widest row's ink,
    /// how bright the sheet is, and how much of that row is bright rather than at the dim base.
    private static func capture(_ view: NSView, at timeMs: Int, elapsedMs: Double = 0) -> TracedFrame? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.bitmapData, rep.samplesPerPixel >= 4 else { return nil }

        let samples = rep.samplesPerPixel
        let rowBytes = rep.bytesPerRow
        var columnAlpha = [UInt8](repeating: 0, count: rep.pixelsWide)
        for y in 0 ..< rep.pixelsHigh {
            let row = data + y * rowBytes
            for x in 0 ..< rep.pixelsWide where row[x * samples + 3] > columnAlpha[x] {
                columnAlpha[x] = row[x * samples + 3]
            }
        }

        let inked = columnAlpha.indices.filter { columnAlpha[$0] > 20 }
        guard let minX = inked.first, let maxX = inked.last, maxX > minX else { return nil }

        // The bright end of the sheet's widest row. Three quarters of the brightest ink on screen:
        // the line that is leaving is still at full opacity when it leaves, and the rows around it
        // are not.
        let peak = Int(columnAlpha.max() ?? 0)
        let lit = columnAlpha.indices.last { $0 >= minX && Int(columnAlpha[$0]) >= peak * 3 / 4 } ?? minX

        return TracedFrame(
            timeMs: timeMs,
            elapsedMs: elapsedMs,
            minX: minX,
            maxX: maxX,
            peak: peak,
            sungReach: Double(min(max(lit, minX), maxX) - minX) / Double(maxX - minX)
        )
    }

    /// Plays into the wide line and across the moment the sheet travels away from it, recording what
    /// the panel drew on the way.
    private func traceDeparture(sheet: SyncedLyrics, playFromMs: Int, leavingLineAt: Int) -> DepartureTrace {
        let changes = KaraokeFillModel.lineChanges(in: sheet)
        guard changes.indices.contains(leavingLineAt + 1) else {
            Issue.record("the sheet has no line after the one under test")
            return DepartureTrace(frames: [], leadStartMs: 0, batonMs: 0, fullWidth: 0, fullPeak: 0, departureIndex: nil)
        }
        let leadStartMs = Int(changes[leavingLineAt + 1].scrollStartMs.rounded())
        let batonMs = Int(changes[leavingLineAt + 1].batonMs.rounded())

        let driver = EmphasisDriver()
        let window = self.host(driver, lyrics: sheet)
        guard let hosting = window.contentView as? NSHostingView<EmphasisHarness> else {
            Issue.record("the harness did not install its content view")
            return DepartureTrace(frames: [], leadStartMs: leadStartMs, batonMs: batonMs, fullWidth: 0, fullPeak: 0, departureIndex: nil)
        }
        defer { window.orderOut(nil) }

        self.pump(0.4)
        var frames: [TracedFrame] = []

        // Inside the wide line, so it is the line being sung at full scale.
        driver.currentTimeMs = playFromMs
        self.pump(0.6)
        frames += self.record(hosting, at: playFromMs, for: 0.05)

        // Then the 100 ms steps the WebView's lyrics poll reports at, up to the last one before the
        // sheet starts travelling. One capture per window is enough here: nothing on this row moves
        // until the travel begins.
        var time = playFromMs + 100
        while time < leadStartMs - 100 {
            driver.currentTimeMs = time
            self.pump(0.1)
            if let frame = Self.capture(hosting, at: time) {
                frames.append(frame)
            }
            time += 100
        }

        // The last sample before the travel, ten milliseconds out: this is the frame the line under
        // test is still at its sung size on, and the one the fill it has reached is measured on.
        driver.currentTimeMs = leadStartMs - 10
        self.pump(0.15)
        frames += self.record(hosting, at: leadStartMs - 10, for: 0.05)

        // The change itself: the sheet starts travelling to the line below, and the row under test
        // leaves with it. The whole lead is recorded — and the baton is never published, so nothing
        // the trace measures can be the change that used to arrive after the sheet had moved.
        let leadStartedAt = Date()
        driver.currentTimeMs = leadStartMs
        frames += self.record(hosting, at: leadStartMs, for: 0.6, since: leadStartedAt)

        let before = frames.filter { $0.timeMs < leadStartMs }
        let fullWidth = before.map(\.maxX).max() ?? 0
        let fullPeak = before.map(\.peak).max() ?? 0
        let tolerance = max(2, fullWidth / 400)
        let departureIndex = frames.firstIndex { $0.maxX <= fullWidth - tolerance }

        return DepartureTrace(
            frames: frames,
            leadStartMs: leadStartMs,
            batonMs: batonMs,
            fullWidth: fullWidth,
            fullPeak: fullPeak,
            departureIndex: departureIndex
        )
    }

    /// What a departure has to look like, at the sampling rate this harness can manage.
    private func expectSmoothDeparture(_ trace: DepartureTrace) -> [Int] {
        guard trace.fullWidth > 0, let departure = trace.departureIndex else {
            Issue.record("the departing line never moved, so there was no departure to measure")
            return []
        }

        let widths = trace.frames[departure...].map(\.maxX)
        let total = trace.fullWidth - (widths.last ?? trace.fullWidth)
        let steps = zip(widths, widths.dropFirst()).map { $0 - $1 }

        // The change arrives over several sampled frames rather than in one…
        #expect(Set(widths).count >= 2, "only \(Set(widths).count) distinct widths across the departure")

        // …the first frame it is seen on is nowhere near where it ends up (a step change would be
        // there already)…
        #expect(
            (widths.first ?? 0) - (widths.last ?? 0) >= max(2, total / 5),
            "the departure was most of the way over on its first frame"
        )

        // …no single sampled frame carries most of it…
        #expect((steps.max() ?? 0) <= max(4, total * 4 / 5), "a single frame moved \((steps.max() ?? 0))px of \(total)")

        // …it only ever shrinks (a spring that overshoots would be visible as growth)…
        #expect((steps.min() ?? 0) >= -1, "the line grew back mid-departure")

        // …and the line really did scale down, so this is not a no-op test.
        #expect(total >= 5, "the line shrank by only \(total)px")

        return widths
    }

    // MARK: - Sheets

    /// Nine two-second lines, the fourth of them far wider than the others, so the row under test is
    /// the widest ink on screen whether it is the line being sung or the line that has left.
    private static func sheet(wideLineWords: [TimedWord]?) -> SyncedLyrics {
        SyncedLyrics(
            lines: (0 ..< 9).map { index in
                SyncedLyricLine(
                    timeInMs: index * 2000,
                    duration: 2000,
                    text: index == 4 ? "W WWWWWWWWWWWWWWW" : "alpha bravo",
                    words: wideLineWords.map { index == 4 ? $0 : Self.narrowLineWords(startMs: index * 2000) }
                )
            },
            source: "EmphasisAnimationTest"
        )
    }

    private static func narrowLineWords(startMs: Int) -> [TimedWord] {
        [
            TimedWord(timeInMs: startMs, word: "alpha"),
            TimedWord(timeInMs: startMs + 1000, word: " bravo"),
        ]
    }

    /// The wide line's word timings: a one-letter first word, and a last word that fills only in the
    /// line's last 180 ms (its ramp ends 40 ms before the line does, from the release tail). A last
    /// word that fills that late is what makes "was this line still being sung when it left?" a
    /// question the pixels can answer: the sheet starts travelling for the next line a whole scroll
    /// lead before that line's baton, and this word is still about two thirds swept when it does.
    private static let wideLineWords = [
        TimedWord(timeInMs: 8000, word: "W"),
        TimedWord(timeInMs: 9850, word: " WWWWWWWWWWWWWWW"),
    ]

    /// Hosts the real panel in an offscreen window, so the widest row is visible from the first frame
    /// and the auto-scroll cannot change which row is being measured.
    private func host(_ driver: EmphasisDriver, lyrics: SyncedLyrics) -> NSWindow {
        let hosting = NSHostingView(rootView: EmphasisHarness(driver: driver, lyrics: lyrics))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 320)
        hosting.wantsLayer = true
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)
        return window
    }

    // MARK: - The line that leaves rides the scroll

    @Test("A row being sung is bright in the anchor and on the falloff once the sheet travels past it")
    func sungRowLeavesWithTheScroll() {
        // With the sheet still anchored on it, the line being sung has the sung look.
        #expect(
            LyricLineEmphasis.emphasis(forLineAt: 3, status: .current, focusIndex: 3) == .current,
            "the line being sung, with the sheet anchored on it, is not drawn at its sung look"
        )

        // The moment the sheet travels to the line below, the sung row is that anchor's neighbour and
        // takes the falloff — the same move its neighbours make, starting with the scroll.
        let leaving = LyricLineEmphasis.emphasis(forLineAt: 3, status: .current, focusIndex: 4)
        #expect(leaving == LyricLineEmphasis.values(distance: -1))
        #expect(leaving.scale < LyricLineEmphasis.current.scale, "the row the sheet travelled past kept its full size")
        #expect(leaving.opacity < LyricLineEmphasis.current.opacity, "…and its full brightness")

        // The baton changes nothing on the row it has left: its move is the scroll's, so there is no
        // second animation left to interrupt the page once the sheet has arrived.
        #expect(
            LyricLineEmphasis.emphasis(forLineAt: 3, status: .previous, focusIndex: 4) == leaving,
            "the departing row changed shape again when the baton passed"
        )
    }

    @Test("The line the sheet has travelled past starts to shrink while it is still being sung")
    func departureStartsWithTheScroll() {
        let wideLine = Self.sheet(wideLineWords: Self.wideLineWords).lines[4]
        let layout = KaraokeLineLayout(line: wideLine, fontSize: 16)
        let rowWidth = zip(layout.textWidths, layout.gaps).reduce(CGFloat(0)) { $0 + $1.0 + $1.1 }
        #expect(rowWidth < 288, "the harness's wide line must stay on one row for the trace to mean anything")

        let trace = self.traceDeparture(
            sheet: Self.sheet(wideLineWords: Self.wideLineWords),
            playFromMs: 8200,
            leavingLineAt: 4
        )
        guard let startOfLead = trace.frames.first(where: { $0.timeMs >= trace.leadStartMs }),
              let endOfLead = trace.endOfLead
        else {
            Issue.record("the sheet drew nothing while it was travelling")
            return
        }

        // On the frame the sheet starts travelling, this row is still in the middle of its fill — the
        // last word of the line only fills in its final 180 ms, just before the line below begins.
        #expect(
            startOfLead.sungReach < 0.5,
            "the row had finished filling before the sheet travelled (\(startOfLead.sungReach.formatted(.number.precision(.fractionLength(2)))) sung), so this is not the case being pinned"
        )

        // The column is anchored on the scroll, so the row the sheet leaves has to have left with it.
        // It used to keep its full size and full brightness until the next line's baton — half a second
        // after the page had already arrived — and then shrink and fade on an animation of its own:
        // the second, interrupting move. By the time the lead runs out, its move is finished.
        #expect(
            endOfLead.maxX <= trace.fullWidth - max(3, trace.fullWidth / 100),
            "the row was still \(endOfLead.maxX)px of \(trace.fullWidth)px wide at the end of the scroll lead (baton at \(trace.batonMs) ms)"
        )
        #expect(
            endOfLead.peak <= trace.fullPeak * 3 / 4,
            "the row was still at \(endOfLead.peak) of \(trace.fullPeak) alpha at the end of the scroll lead (baton at \(trace.batonMs) ms)"
        )

        // The departure across the lead is still a spring, not a snap.
        _ = self.expectSmoothDeparture(trace)
    }

    // MARK: - The departure is smooth for a whole-line lyric too

    @Test("The line that has just been sung scales down over several frames instead of snapping")
    func leavingLineScalesDownSmoothly() {
        let trace = self.traceDeparture(
            sheet: Self.sheet(wideLineWords: nil),
            playFromMs: 8200,
            leavingLineAt: 4
        )

        _ = self.expectSmoothDeparture(trace)
    }
}

// MARK: - Harness

/// The playback position the harness publishes, in the 100 ms steps the lyrics poll uses.
@MainActor
@Observable
fileprivate final class EmphasisDriver {
    var currentTimeMs = 0
}

@MainActor
private struct EmphasisHarness: View {
    let driver: EmphasisDriver
    let lyrics: SyncedLyrics

    var body: some View {
        SyncedLyricsDisplayView(
            lyrics: self.lyrics,
            currentTimeMs: self.driver.currentTimeMs,
            isPlaying: true,
            // The trace reads the row's own departure out of its pixels, and its sampling floor was
            // calibrated against the lighter renderer. Which word animation is drawn inside the row
            // is a separate axis (`RichLyricsRenderTests`, `KaraokeLyricsPerformanceTests`), and the
            // row leaves at the same rate under both, so this pins the one the trace can sample.
            animationStyle: .appleMusic,
            onSeek: { _ in }
        )
    }
}
