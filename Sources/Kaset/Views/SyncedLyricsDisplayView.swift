import SwiftUI

// MARK: - SyncedLyricsDisplayView

struct SyncedLyricsDisplayView: View {
    let lyrics: SyncedLyrics
    let currentTimeMs: Int
    /// Whether playback is running, so the display clock can freeze and slew.
    let isPlaying: Bool
    /// Strength of the karaoke glow and lift. The narrow panel carries less of it
    /// than the fullscreen view does.
    var emphasis: Double = 0.55
    /// Whether something is drawn over this sheet — the fullscreen player covers it.
    ///
    /// A covered sheet draws nothing at all: every row of it is settled, so no timeline of its is
    /// unpaused (`KaraokeFrameBudget.plan`). Its highlight still has to stay correct, which is done
    /// from the playback samples instead (`receiveClockSample`), so the sheet is already showing the
    /// right line when it is revealed rather than slewing to it in front of the reader.
    var isCovered: Bool = false
    /// The word animation to draw with, overriding the reader's setting, which is what `nil` uses —
    /// and what the panel and the sidebar leave it at. A caller that is tracing the rows rather than
    /// the words pins one.
    var animationStyle: LyricsAnimationStyle?
    /// Whether the sheet may be scrolled by hand.
    ///
    /// The Now Playing sidebar shows this same sheet in a window three lines tall, where the
    /// highlight is always the middle line: a stray two-finger scroll there would push the line being
    /// sung out of the window and stop the sheet following playback for the next four seconds. The
    /// sheet is still driven programmatically (it keeps centering the current line), it just cannot
    /// be dragged by the reader.
    var allowsScrolling: Bool = true
    let onSeek: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The word animation the reader chose, read here so a change of style reaches every row.
    @State private var settings = SettingsManager.shared
    /// Interpolated playback clock. Only the line being sung reads it, and it lives
    /// here so the highlight survives line changes and view re-renders.
    @State private var clock = LyricsPlaybackClock()
    /// Measured line layouts, kept across the sheet's re-renders.
    @State private var layoutCache = KaraokeLayoutCache()
    /// Every moment this sheet's line state changes, built from its lines once
    /// (`KaraokeFillModel.lineChanges`): which line takes the baton when, and when the sheet starts
    /// travelling to it. Playback only ever searches this, so no sample derives anything.
    @State private var changes: [KaraokeLineChange]
    /// The pending wake-up at the next change, so a line change lands on its own moment instead of
    /// on the next 10 Hz sample.
    @State private var wakeUp = KaraokeChangeWakeUp()
    /// The change the wake-up is currently armed for, so re-arming for the same moment is skipped.
    @State private var armedChangeMs: Double?
    /// The line being sung: what the rows' emphasis, the pause dots and the rows' liveness are keyed
    /// to, and the **only** row drawn bright. It moves when a line's own content opens
    /// (`KaraokeFillModel.lineChanges`), so the baton passes on the frame its first word starts
    /// filling.
    @State private var currentLineIndex: Int?
    /// The line the sheet is travelling to: the line being sung, or the line after it once its first
    /// word is `KaraokeTiming.scrollLeadMs` away (`KaraokeFillModel.scrollIndex`). Kept apart from the
    /// highlight because they are two different times — the sheet has to be in place *before* the
    /// line is sung, and only then does that line take the emphasis.
    @State private var scrollLineId: UUID?
    /// Whether the panel is still putting itself in position: its first paint (a whole lyric
    /// sheet) is the most expensive frame of its life, and the sidebar is sliding in at the
    /// same time, so during that window the sheet *jumps* instead of scrolling. This is about
    /// where the sheet is, never about how a line changes — it must not be allowed to gate the
    /// rows' emphasis (see the initializer for why).
    @State private var isSettling = true
    /// Whether the user has manually scrolled (pauses auto-scroll).
    @State private var userIsScrolling = false
    /// Timer task to resume auto-scroll after user interaction.
    @State private var scrollResumeTask: Task<Void, Never>?
    @State private var resumeScrollGeneration = 0

    /// How this row draws this frame: whether it runs on the display clock at all, and how often it
    /// may redraw. One decision, taken in one place (`KaraokeFrameBudget.plan`), because the two
    /// answers are the same decision — a row whose timeline is paused is handed its settled frame
    /// once and then draws nothing.
    private func plan(forLineAt index: Int) -> KaraokeRowPlan {
        KaraokeFrameBudget.plan(
            isLive: self.isLive(lineIndex: index),
            isCurrent: index == self.currentLineIndex,
            isCovered: self.isCovered,
            reduceMotion: self.reduceMotion,
            isPlaying: self.isPlaying
        )
    }

    /// The Better Lyrics timing the rows draw with: the same animation, with the word's sideways
    /// slide put back if the reader asked for it. Resolved by the setting itself, so the two sheets
    /// cannot disagree about what "off" means.
    private var richTiming: RichLyricsTiming {
        self.settings.richLyricsTiming
    }

    private var karaokeEmphasis: Double {
        self.reduceMotion ? 0 : self.emphasis
    }

    /// Seeds the sheet's highlight from the playback position, so its very first frame is
    /// already the right one.
    ///
    /// The highlight used to be applied a frame after the sheet appeared, and that pop-in was
    /// papered over by suppressing the rows' emphasis animation for as long as the panel's
    /// settling task ran (`isSettling`). That window is long-lived — it restarts whenever the
    /// lyric sheet is replaced and stretches while the main thread is busy, which is exactly
    /// when a line changes — so a line change inside it had no animation at all. The departing
    /// line's scale, opacity and drift were applied instantly while its words kept animating,
    /// because the word fill is driven by the display clock rather than by an implicit
    /// animation. Seeding the highlight removes the pop-in itself, so the emphasis animation
    /// never has to be switched off and a line change always animates.
    init(
        lyrics: SyncedLyrics,
        currentTimeMs: Int,
        isPlaying: Bool,
        emphasis: Double = 0.55,
        isCovered: Bool = false,
        allowsScrolling: Bool = true,
        animationStyle: LyricsAnimationStyle? = nil,
        onSeek: @escaping (Int) -> Void
    ) {
        self.lyrics = lyrics
        self.currentTimeMs = currentTimeMs
        self.isPlaying = isPlaying
        self.emphasis = emphasis
        self.animationStyle = animationStyle
        self.isCovered = isCovered
        self.allowsScrolling = allowsScrolling
        self.onSeek = onSeek

        let changes = KaraokeFillModel.lineChanges(in: lyrics)
        _changes = State(initialValue: changes)

        let highlightIndex = KaraokeFillModel.highlightIndex(in: changes, at: Double(currentTimeMs))
        _currentLineIndex = State(initialValue: highlightIndex)

        let scrollIndex = KaraokeFillModel.scrollIndex(in: changes, at: Double(currentTimeMs))
        _scrollLineId = State(initialValue: scrollIndex.map { lyrics.lines[$0].id })
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 60)

                    ForEach(Array(self.lyrics.lines.enumerated()), id: \.element.id) { index, line in
                        let status = self.currentStatus(for: index)
                        let plan = self.plan(forLineAt: index)
                        // A line with nothing to sing is a pause, and a pause is the dots. The
                        // test is the same one the dots themselves use, so the row that draws
                        // them and the state they are drawn from cannot disagree.
                        if self.lyrics.isPauseLine(at: index) {
                            // When this silence began — asked of the line *above* it, and measured from
                            // that line's own words — is settled once for the row, not once per frame:
                            // only the dots' state is a function of the display position.
                            let interlude = self.lyrics.pauseInterlude(forLineAt: index)
                            KaraokeTimeSource(
                                line: line,
                                status: status,
                                isLive: plan.isLive,
                                clock: self.clock,
                                minimumFrameInterval: plan.minimumInterval
                            ) { displayTimeMs in
                                SyncedPauseDotsLineView(
                                    dots: SyncedLyrics.PauseDots(interlude: interlude, at: Int(displayTimeMs)),
                                    status: status,
                                    isTrailingAligned: self.lyrics.isTrailingAligned(at: index),
                                    onTap: { self.onSeek(line.timeInMs) }
                                )
                            }
                            .id(line.id)
                        } else {
                            SyncedLineView(
                                line: line,
                                lineIndex: index,
                                isTrailingAligned: self.lyrics.isTrailingAligned(at: index),
                                status: status,
                                isLive: plan.isLive,
                                clock: self.clock,
                                layoutCache: self.layoutCache,
                                minimumFrameInterval: plan.minimumInterval,
                                emphasis: self.karaokeEmphasis,
                                style: self.animationStyle ?? self.settings.lyricsAnimationStyle,
                                richTiming: self.richTiming,
                                onTap: { self.onSeek(line.timeInMs) }
                            )
                            .id(line.id)
                        }
                    }

                    // The submitter credit belongs to the lyrics, not to the panel:
                    // it sits at the end of the sheet, out of the way until read to
                    // the bottom.
                    if let attribution = self.lyrics.attribution, attribution.hasSubmitter {
                        LyricsSubmitterCredit(attribution: attribution)
                            .padding(.top, 28)
                    }

                    Spacer().frame(height: 120)
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(!self.allowsScrolling)
            // Attach scrolling state to the actual ScrollView rather than relying
            // on a competing gesture recognizer over its content.
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting:
                    self.userIsScrolling = true
                    self.resumeScrollGeneration += 1
                    self.scrollResumeTask?.cancel()
                case .decelerating:
                    let generation = self.resumeScrollGeneration
                    self.scrollResumeTask?.cancel()
                    self.scrollResumeTask = Task {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled, generation == self.resumeScrollGeneration else { return }
                        self.userIsScrolling = false
                        self.scrollToCurrentLine(using: proxy, animated: true)
                    }
                default:
                    break
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        self.userIsScrolling = true
                        self.resumeScrollGeneration += 1
                        self.scrollResumeTask?.cancel()
                    }
                    .onEnded { _ in
                        let generation = self.resumeScrollGeneration
                        self.scrollResumeTask = Task {
                            try? await Task.sleep(for: .seconds(4))
                            guard !Task.isCancelled, generation == self.resumeScrollGeneration else { return }
                            self.userIsScrolling = false
                            self.scrollToCurrentLine(using: proxy, animated: true)
                        }
                    }
            )
            .onChange(of: self.currentTimeMs) { _, newTimeMs in
                self.receiveClockSample(timeMs: newTimeMs, isPlaying: self.isPlaying)
                self.syncCurrentLine(at: Double(newTimeMs), proxy: proxy, animate: !self.userIsScrolling)
                self.armNextChange(using: proxy)
            }
            .onChange(of: self.isPlaying) { _, newIsPlaying in
                // The poll keeps reporting the same position while paused, so it takes
                // the play state to freeze the clock instead of extrapolating past it.
                self.receiveClockSample(timeMs: self.currentTimeMs, isPlaying: newIsPlaying)
                self.armNextChange(using: proxy)
            }
            .onChange(of: self.lyrics) { _, newLyrics in
                // A new track's lyrics start at zero: without this the old clock
                // position would flash the new first line as already sung.
                self.changes = KaraokeFillModel.lineChanges(in: newLyrics)
                self.clock.reset()
                self.armedChangeMs = nil
                self.receiveClockSample(timeMs: self.currentTimeMs, isPlaying: self.isPlaying)
                self.syncCurrentLine(at: 0, proxy: proxy, animate: false)
                self.armNextChange(using: proxy)
                Task { await self.settleScroll(using: proxy) }
            }
            .onAppear {
                self.receiveClockSample(timeMs: self.currentTimeMs, isPlaying: self.isPlaying)
                self.syncCurrentLine(at: Double(self.currentTimeMs), proxy: proxy, animate: false)
                self.armNextChange(using: proxy)
                SingletonPlayerWebView.shared.startLyricsPoll()
                SingletonPlayerWebView.shared.sendCurrentLyricsTime()
            }
            .task {
                await self.settleScroll(using: proxy)
            }
            .onDisappear {
                self.scrollResumeTask?.cancel()
                self.wakeUp.cancel()
            }
        }
    }

    private func receiveClockSample(timeMs: Int, isPlaying: Bool) {
        self.clock.receive(LyricsClockSample(hostTime: Date(), timeMs: timeMs, isPlaying: isPlaying))
        // While the fullscreen player covers this sheet no row runs on the display clock, so nothing
        // else advances it: it is advanced here instead, once per playback sample.
        //
        // The clock has to keep moving for two reasons. `KaraokeFillModel.isLiveRow` reads its
        // position, so a sheet revealed over a stale clock would put the wrong rows on the clock
        // for a frame. And the reveal itself draws from the clock, so a sheet whose clock had been
        // left at the position it was covered on would slew to the right one — or snap to it — in
        // front of the reader, instead of already being there.
        if self.isCovered {
            self.clock.advance(to: Date())
        }
    }

    /// Puts the sheet in position after it appears or after it is replaced, and turns the
    /// panel's transitions back on once it has.
    ///
    /// The lazy stack has usually not materialized the scroll target yet, and scrolling to a
    /// row that does not exist does nothing — which left the panel opening at the wrong
    /// position, after which the first line change animated a scroll from there. A jump is
    /// repeated instead: it never animates, so repeating it is invisible, and it always reads
    /// the target from state rather than from the playback time the caller captured (that
    /// value is frozen for the life of this task, and writing the highlight from it dragged
    /// the highlight back to wherever playback was when the panel opened).
    private func settleScroll(using proxy: ScrollViewProxy) async {
        self.isSettling = true
        defer { self.isSettling = false }

        // Bounded by wall clock, not by iteration count: a busy main thread (which is what
        // this window exists for) stretches `Task.sleep`, so counting sleeps left the sheet
        // jumping instead of scrolling for far longer than the frame it was meant to cover.
        let deadline = Date().addingTimeInterval(0.6)
        for _ in 0 ..< 10 {
            guard !Task.isCancelled, !self.userIsScrolling else { return }
            await Task.yield()
            if let scrollLineId = self.scrollLineId {
                proxy.scrollTo(scrollLineId, anchor: .center)
            }
            guard Date() < deadline else { return }
            try? await Task.sleep(for: .milliseconds(70))
        }
    }

    /// Whether this row draws from the live display clock. See
    /// `KaraokeFillModel.isLiveRow` for why the line that has just finished is included:
    /// a row that switches between the live and settled frames *while* its status changes
    /// has its subtree replaced mid-transition, and SwiftUI does not animate that.
    private func isLive(lineIndex: Int) -> Bool {
        let line = self.lyrics.lines.indices.contains(lineIndex) ? self.lyrics.lines[lineIndex] : nil
        return KaraokeFillModel.isLiveRow(
            lineIndex: lineIndex,
            currentLineIndex: self.currentLineIndex,
            line: line,
            clockMs: self.clock.displayPositionMs
        )
    }

    /// Moves the highlight and the scroll together, from one playback sample.
    ///
    /// The two ask different questions of the same position. The **highlight** is the line being
    /// sung right now, so the baton passes when its first word starts filling and the line above
    /// keeps it until then: one row is bright at a time. The **scroll** has to arrive before that,
    /// which is why it follows `scrollIndex` — the line after the current one, `scrollLeadMs`
    /// before its first word — and travels in `scrollDurationMs`, so it is in place with the rest
    /// of the lead to spare. Neither decision can make the other late: the sheet is already there
    /// when the baton passes.
    private func syncCurrentLine(at positionMs: Double, proxy: ScrollViewProxy, animate: Bool) {
        self.updateHighlight(at: positionMs)

        guard let scrollIndex = KaraokeFillModel.scrollIndex(in: self.changes, at: positionMs) else { return }
        let id = self.lyrics.lines[scrollIndex].id
        let targetChanged = id != self.scrollLineId
        self.scrollLineId = id
        guard targetChanged, !self.userIsScrolling else { return }
        // While the panel is still opening, jump: an animated scroll competing with the
        // open animation and the sheet's first paint is what made it stutter.
        if animate, !self.isSettling {
            Self.travel(using: proxy, to: id)
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    /// Wakes the sheet at the next moment its state changes, so a line change is not left waiting for
    /// the next playback sample (the poll reports at 10 Hz, which on a fast line is long enough for a
    /// word to be sung by a row that is not the current one yet).
    ///
    /// One wake-up at a time, and none at all while paused or covered: the clock is not moving then,
    /// so there is no moment to wake at.
    private func armNextChange(using proxy: ScrollViewProxy) {
        guard self.isPlaying, !self.isCovered, !self.changes.isEmpty else {
            self.armedChangeMs = nil
            self.wakeUp.cancel()
            return
        }
        let now = self.clock.displayPositionMs
        guard let due = KaraokeFillModel.nextChangeMs(in: self.changes, after: now), due != self.armedChangeMs else {
            return
        }
        self.armedChangeMs = due
        self.wakeUp.arm(afterMs: max(1, due - now)) {
            self.syncCurrentLine(at: self.clock.displayPositionMs, proxy: proxy, animate: !self.userIsScrolling)
            self.armedChangeMs = nil
            self.armNextChange(using: proxy)
        }
    }

    /// The sheet's own travel: the one duration every scroll to a line uses, short enough to finish
    /// inside `KaraokeTiming.scrollLeadMs`.
    private static func travel(using proxy: ScrollViewProxy, to id: UUID) {
        withAnimation(.easeInOut(duration: KaraokeTiming.standard.scrollDurationMs / 1000)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    /// Moves the highlight onto the line being sung (see `KaraokeFillModel.lineChanges`).
    private func updateHighlight(at positionMs: Double) {
        guard let index = KaraokeFillModel.highlightIndex(in: self.changes, at: positionMs) else { return }
        self.currentLineIndex = index
    }

    private func scrollToCurrentLine(using proxy: ScrollViewProxy, animated: Bool) {
        guard let id = self.scrollLineId else { return }
        if animated {
            Self.travel(using: proxy, to: id)
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func currentStatus(for lineIndex: Int) -> SyncedLyrics.LineStatus {
        KaraokeFillModel.status(forLineAt: lineIndex, highlightIndex: self.currentLineIndex)
    }

}

// MARK: - KaraokeChangeWakeUp

/// One pending look at the display clock, at a moment the clock has not reached yet.
///
/// The lyrics poll reports at 10 Hz. A line change is a moment *inside* one of those windows — the
/// sheet starting to travel for the next line, and that line taking the baton on its first word —
/// so read from the samples alone the change lands up to 100 ms late. On a fast line that is a word
/// already part-filled on a row that has not been made the current one yet, and the sheet arriving
/// after the first word has been sung.
///
/// Only one wake-up exists at a time and it is replaced rather than added to, so a seek, a pause or
/// a fresh sample that re-arms it can never leave two behind. What it does is recomputed from the
/// clock when it fires, so a wake-up that does outlive the reason it was armed for can only apply the
/// state the sheet is already in.
@MainActor
final class KaraokeChangeWakeUp {
    private var task: Task<Void, Never>?

    /// Arms the single wake-up, replacing whatever was pending.
    func arm(afterMs delayMs: Double, fire: @escaping @MainActor () -> Void) {
        self.cancel()
        self.task = Task {
            try? await Task.sleep(for: .milliseconds(max(1, Int(delayMs.rounded()))))
            guard !Task.isCancelled else { return }
            fire()
        }
    }

    func cancel() {
        self.task?.cancel()
        self.task = nil
    }
}

// MARK: - KaraokeFrameBudget

/// What a lyric row may spend on a frame.
@available(macOS 26.0, *)
enum KaraokeFrameBudget {
    /// The line being sung redraws 60 times a second.
    ///
    /// A karaoke wipe is a slow fill — a few pixels a frame — so 60 is already smoother
    /// than the eye can follow, while a 120 Hz display would pay twice as much for frames
    /// nobody can see. Halving the rate is the single cheapest thing to do about the
    /// animation's cost, and it changes nothing about the animation itself.
    static let live = 1.0 / 60.0

    /// A row that is on the clock but is not the one being sung redraws at half that: the line
    /// after the current one once it is close enough to its own first ramp to take the clock
    /// (`KaraokeFillModel.isLiveRow`), and the line that has just finished until its content is
    /// settled. They are filled by the same clock so they arrive without a jump, and the rate
    /// costs nothing because what is on them is Core Animation's, not a redraw of ours.
    static let armed = 1.0 / 30.0

    /// While playback is paused the fill is frozen, so a row's frames only exist to take up
    /// a sample correction or a seek — 20 a second is prompt enough for both, and it stops
    /// a paused lyric sheet from repainting an unchanging line 60 times a second.
    static let paused = 1.0 / 20.0

    /// Reduce Motion keeps the fill — it is the information — but drops the decorative
    /// motion and the display-rate redraw that goes with it.
    static let reducedMotion = 1.0 / 20.0

    /// Whether a row runs on the display clock this frame, and how often it may redraw.
    ///
    /// The two answers are one decision — `KaraokeTimeSource` pauses a row's timeline exactly when
    /// it is not live, so an interval only exists for a row that draws — which is why they are
    /// answered together, by the same rule, for both lyric surfaces.
    ///
    /// **A covered row never draws.** A sheet the fullscreen player is drawn over is out of sight
    /// for as long as the player is up, so every one of its rows is settled and the panel behind the
    /// player costs no frames at all. Nothing is lost: its clock is still advanced, from the playback
    /// samples rather than from a display link (`SyncedLyricsDisplayView.receiveClockSample`), so the
    /// sheet is already showing the right line when the reader comes back to it.
    ///
    /// It was previously given a tenth of the live rate, which is still a whole row redrawn ten
    /// times a second — a line being sung under an opaque cover, for nobody.
    static func plan(
        isLive: Bool,
        isCurrent: Bool,
        isCovered: Bool,
        reduceMotion: Bool,
        isPlaying: Bool
    ) -> KaraokeRowPlan {
        guard isLive, !isCovered else { return .settled }
        if reduceMotion { return KaraokeRowPlan(isLive: true, minimumInterval: Self.reducedMotion) }
        if !isPlaying { return KaraokeRowPlan(isLive: true, minimumInterval: Self.paused) }
        return KaraokeRowPlan(isLive: true, minimumInterval: isCurrent ? Self.live : Self.armed)
    }
}

// MARK: - KaraokeRowPlan

/// What one lyric row draws this frame.
///
/// A settled row is not merely throttled: its timeline is paused (`KaraokeTimeSource`), so it is
/// handed its settled position once and then draws nothing at all until the highlight comes back
/// for it. That is what makes a sheet mostly free — a sheet is mostly lines that have been sung —
/// and it is why "may this row draw" and "how often" are one value rather than two.
@available(macOS 26.0, *)
struct KaraokeRowPlan: Equatable {
    /// Whether the row runs on the display clock.
    let isLive: Bool
    /// The fastest the row may redraw, or `nil` when it is settled and draws nothing.
    let minimumInterval: Double?

    /// A row that is not drawing: its timeline is paused and it has no rate.
    static let settled = KaraokeRowPlan(isLive: false, minimumInterval: nil)
}

// MARK: - KaraokeTimeSource

/// Feeds a lyric row the live display clock while it is being animated, and a
/// settled position otherwise.
///
/// This is what keeps the karaoke animation affordable: past and far-off lines
/// render a single static frame, so only the line being sung and the one after it
/// redraw per display frame.
///
/// It is **one** `TimelineView` in both states, paused when the row is settled, and
/// the two states differ only in which position that timeline hands the content.
/// That is deliberate, and it is the whole point of the type: an `if isLive { … }
/// else { … }` builds `_ConditionalContent`, and switching branches therefore
/// *replaces* the subtree — SwiftUI does not animate a subtree it replaces. The
/// hand-off happens in the same update that changes the row's status, in the middle
/// of the line's departure, so a replacement there is what made the line that had
/// just been sung look like it snapped instead of animating out. A value change
/// inside an unchanged view cannot do that, whatever frame it lands on.
///
/// Pausing, rather than removing, the timeline is also what stops a settled row from
/// redrawing: a line that has finished is a line nothing is happening to, and its
/// departure (scale, opacity, drift, blur) is Core Animation's animation of a frozen
/// raster rather than a per-frame redraw of scaled text.
@available(macOS 26.0, *)
struct KaraokeTimeSource<Content: View>: View {
    let line: SyncedLyricLine
    /// The line's own words, when the caller already has them, so a settled row does
    /// not have to derive them again and again.
    var words: [KaraokeWord] = []
    let status: SyncedLyrics.LineStatus
    /// Whether this row runs on the display clock. The line being sung *and the
    /// line after it* are live, so by the time the highlight moves on, the next
    /// line's fill and swell are already running from their own start — a line can
    /// never first be seen part-way through its first word.
    let isLive: Bool
    let clock: LyricsPlaybackClock
    let minimumFrameInterval: Double?
    @ViewBuilder let content: (Double) -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: self.minimumFrameInterval, paused: !self.isLive)) { timeline in
            self.content(self.position(at: timeline.date))
        }
    }

    /// The playback position to render at: the clock while the row is live, and the
    /// settled frame — fully sung for a line that has finished, untouched for one that has
    /// not started — once it is not.
    private func position(at date: Date) -> Double {
        guard self.isLive else {
            return KaraokeFillModel.staticTimeMs(for: self.status, words: self.words, line: self.line)
        }
        return self.clock.advance(to: date)
    }
}

// MARK: - SyncedPauseDotsLineView

@available(macOS 26.0, *)
struct SyncedPauseDotsLineView: View {
    let dots: SyncedLyrics.PauseDots
    let status: SyncedLyrics.LineStatus
    /// Whether the dots belong against the trailing edge, which is the edge of the line above
    /// them (`SyncedLyrics.isTrailingAligned(at:)`): an interlude inside the other singer's
    /// section is a pause in *their* part, and the dots are drawn where their lines are.
    var isTrailingAligned: Bool = false
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< 3, id: \.self) { dotIndex in
                self.dotView(for: self.status(of: dotIndex))
            }
        }
        .frame(maxWidth: .infinity, alignment: self.isTrailingAligned ? .trailing : .leading)
        .padding(.vertical, 7)
        .opacity(self.lineOpacity(for: self.status))
        .scaleEffect(
            self.lineScale(for: self.status),
            anchor: self.isTrailingAligned ? .trailing : .leading
        )
        .animation(.easeInOut(duration: 0.35), value: self.dots.statuses)
        .animation(AppAnimation.lyricEmphasis, value: self.status)
        .contentShape(Rectangle())
        .onTapGesture {
            self.onTap()
        }
    }

    @ViewBuilder
    private func dotView(for dotStatus: SyncedLyrics.PauseDotStatus) -> some View {
        // The bounce is a value off the row's own display clock, not a timeline of its
        // own: the row is already redrawing per frame while it is the one being sung, and
        // two clocks on one row are two chances to disagree about when that is.
        Circle()
            .fill(Color.primary)
            .frame(width: 7, height: 7)
            .opacity(self.dotOpacity(for: dotStatus))
            .offset(y: dotStatus == .active ? -2.8 * self.dots.lift : 0)
    }

    private func status(of index: Int) -> SyncedLyrics.PauseDotStatus {
        guard self.dots.statuses.indices.contains(index) else { return .notSung }
        return self.dots.statuses[index]
    }

    private func dotOpacity(for status: SyncedLyrics.PauseDotStatus) -> Double {
        switch status {
        case .notSung:
            0.28
        case .active:
            1.0
        case .sung:
            0.65
        }
    }

    private func lineScale(for status: SyncedLyrics.LineStatus) -> CGFloat {
        switch status {
        case .current:
            1.0
        case .previous:
            0.95
        case .upcoming:
            0.965
        }
    }

    private func lineOpacity(for status: SyncedLyrics.LineStatus) -> Double {
        switch status {
        case .current:
            1.0
        case .previous:
            0.35
        case .upcoming:
            0.55
        }
    }
}

// MARK: - SyncedLineView

struct SyncedLineView: View {
    let line: SyncedLyricLine
    /// Index of this line, so the pause-dot lookup never scans the whole lyric sheet.
    let lineIndex: Int
    /// The edge this row is drawn against, which the sheet resolves — a line from its own
    /// singer, a row with nothing to sing from the line above it
    /// (`SyncedLyrics.isTrailingAligned(at:)`).
    let isTrailingAligned: Bool
    let status: SyncedLyrics.LineStatus
    let isLive: Bool
    let clock: LyricsPlaybackClock
    /// Measured line layouts, so a re-render of the sheet never measures a line again.
    let layoutCache: KaraokeLayoutCache
    let minimumFrameInterval: Double?
    let emphasis: Double
    /// How the line's words animate as they are sung.
    let style: LyricsAnimationStyle
    /// The Better Lyrics timing to draw with, when that is the style.
    var richTiming: RichLyricsTiming = .standard
    let onTap: () -> Void

    private static let fontSize: CGFloat = 16

    var body: some View {
        // Measured once per line, not once per frame or per sheet re-render: a frame of
        // the wipe of this line is then arithmetic and drawing only. The backing vocal is
        // measured at its own smaller size and cached under its own key, so the two
        // layouts of one row never evict each other.
        let layout = self.layoutCache.layout(for: self.line, fontSize: Self.fontSize)
        let backgroundLayout = self.layoutCache.backgroundLayout(for: self.line, fontSize: Self.fontSize - 2)

        return KaraokeTimeSource(
            line: self.line,
            words: layout.words,
            status: self.status,
            isLive: self.isLive,
            clock: self.clock,
            minimumFrameInterval: self.minimumFrameInterval
        ) { displayTimeMs in
            self.content(at: displayTimeMs, layout: layout, backgroundLayout: backgroundLayout)
        }
        .frame(maxWidth: .infinity, alignment: self.alignment)
        .opacity(self.opacity(for: self.status))
        // Anchored to the edge the row sits on, so an other-singer line grows and shrinks
        // from its own side rather than sliding across the panel.
        .scaleEffect(self.scale(for: self.status), anchor: self.alignment == .trailing ? .trailing : .leading)
        .offset(y: self.drift(for: self.status))
        .padding(.vertical, 5)
        // Always animated, including the line that is leaving. A line change is the panel's
        // most visible piece of motion and it must never be conditional — see the panel's
        // initializer for the bug that a conditional here caused.
        .animation(AppAnimation.lyricEmphasis, value: self.status)
        .contentShape(Rectangle())
        .onTapGesture {
            self.onTap()
        }
    }

    /// The edge this row is drawn against: a duet's second singer gets the trailing one.
    private var alignment: Alignment {
        self.isTrailingAligned ? .trailing : .leading
    }

    @ViewBuilder
    private func content(at displayTimeMs: Double, layout: KaraokeLineLayout, backgroundLayout: KaraokeLineLayout?) -> some View {
        let hasLead = !self.line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if !hasLead, backgroundLayout == nil {
            // A short instrumental gap that is not long enough for the pause dots.
            Text("♪")
                .font(.system(size: Self.fontSize, weight: .bold))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if hasLead {
                    KaraokeLyricsLineView(
                        layout: layout,
                        displayTimeMs: displayTimeMs,
                        color: .primary,
                        emphasis: self.emphasis,
                        lineSpacing: 2,
                        style: self.style,
                        isSettled: self.status == .previous,
                        richTiming: self.richTiming,
                        isTrailingAligned: self.isTrailingAligned
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let backgroundLayout {
                    // The backing vocal is driven by the same display clock position as the
                    // lead: a word-timed one runs the same per-character wipe, and a phrase
                    // the source never timed is drawn as a line-synced row — revealed whole at
                    // the line's start, with no invented word boundaries. It is dimmer and
                    // smaller so it reads as accompaniment.
                    KaraokeLyricsLineView(
                        layout: backgroundLayout,
                        displayTimeMs: displayTimeMs,
                        color: .secondary,
                        emphasis: self.emphasis,
                        lineSpacing: 2,
                        style: self.style,
                        isSettled: self.status == .previous,
                        richTiming: self.richTiming,
                        isTrailingAligned: self.isTrailingAligned
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func scale(for status: SyncedLyrics.LineStatus) -> CGFloat {
        switch status {
        case .current:
            1.0
        case .previous:
            0.95
        case .upcoming:
            0.965
        }
    }

    private func opacity(for status: SyncedLyrics.LineStatus) -> Double {
        switch status {
        case .current:
            1.0
        case .previous:
            0.35
        case .upcoming:
            0.55
        }
    }

    /// Neighbouring lines sit slightly off their slot, so a line settles into place
    /// as it becomes the line being sung.
    private func drift(for status: SyncedLyrics.LineStatus) -> CGFloat {
        switch status {
        case .current:
            0
        case .previous:
            -3
        case .upcoming:
            3
        }
    }
}
