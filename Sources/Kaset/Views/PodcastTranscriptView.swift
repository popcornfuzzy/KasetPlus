import SwiftUI

// MARK: - PodcastTranscriptStyle

/// How a transcript is drawn on the surface it sits on.
///
/// The fullscreen player draws it white over the darkened video with pinned chapter headings; the
/// Now Playing column draws the same rows at reading size on the sidebar's own background. Emphasis
/// rides on opacity and a scale transform in both, never on the font, so a paragraph moving through
/// playback never re-flows.
struct PodcastTranscriptStyle: Equatable {
    var fontSize: CGFloat
    var weight: Font.Weight
    var lineSpacing: CGFloat
    /// Gap between paragraphs.
    var paragraphSpacing: CGFloat
    /// Colour paragraphs and chapter headings are drawn in.
    var textColor: Color
    var currentOpacity: Double
    var spokenOpacity: Double
    var upcomingOpacity: Double
    var hoveredOpacity: Double
    /// Opacity of a chapter heading that is not the one being listened to.
    var chapterOpacity: Double
    var chapterFontSize: CGFloat
    /// Whether chapter headings stay on screen while their paragraphs scroll past.
    var pinsChapterHeadings: Bool
    /// What sits behind a pinned heading, which scrolls underneath it.
    var chapterHeaderBackground: Color
    /// Space above the first and below the last paragraph, so the followed one can sit centred.
    var topInset: CGFloat
    var bottomInset: CGFloat
    /// Accessibility identifier of a chapter heading.
    var chapterHeaderIdentifier: String

    /// The fullscreen podcast experience: large type over the darkened video.
    static let immersive = PodcastTranscriptStyle(
        fontSize: 24,
        weight: .semibold,
        lineSpacing: 8,
        paragraphSpacing: 22,
        textColor: .white,
        currentOpacity: 1,
        spokenOpacity: 0.35,
        upcomingOpacity: 0.55,
        hoveredOpacity: 0.78,
        chapterOpacity: 0.6,
        chapterFontSize: 12,
        pinsChapterHeadings: true,
        chapterHeaderBackground: .black.opacity(0.35),
        topInset: 40,
        bottomInset: 120,
        chapterHeaderIdentifier: AccessibilityID.FullscreenPodcast.chapterHeader
    )

    /// The Now Playing column's card: reading size, no pinned headings over its glass.
    static let sidebar = PodcastTranscriptStyle(
        fontSize: 13,
        weight: .regular,
        lineSpacing: 5,
        paragraphSpacing: 14,
        textColor: .primary,
        currentOpacity: 1,
        spokenOpacity: 0.4,
        upcomingOpacity: 0.72,
        hoveredOpacity: 0.9,
        chapterOpacity: 0.6,
        chapterFontSize: 11,
        pinsChapterHeadings: false,
        chapterHeaderBackground: .clear,
        topInset: 2,
        bottomInset: 8,
        chapterHeaderIdentifier: AccessibilityID.NowPlayingSidebar.transcriptChapterHeader
    )
}

// MARK: - PodcastTranscriptView

/// The scrolling transcript: the paragraph being spoken is highlighted and followed, and clicking a
/// paragraph seeks to it. Chapter headings seek to the start of their section.
@available(macOS 26.0, *)
struct PodcastTranscriptView: View {
    let transcript: PodcastTranscript
    let currentTimeMs: Int
    let onSeek: (Int) -> Void
    var style: PodcastTranscriptStyle = .immersive

    @State private var currentLineId: UUID?
    @State private var currentLineIndex: Int?
    @State private var userIsScrolling = false
    @State private var scrollResumeTask: Task<Void, Never>?
    @State private var resumeScrollGeneration = 0
    @State private var hoveredLineId: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(
                    alignment: .leading,
                    spacing: self.style.paragraphSpacing,
                    // Chapter headings stay put while their paragraphs scroll: the section being
                    // listened to keeps its title on screen, like a transcript picker.
                    pinnedViews: self.style.pinsChapterHeadings ? [.sectionHeaders] : []
                ) {
                    Spacer().frame(height: self.style.topInset)

                    ForEach(self.sections) { section in
                        Section {
                            ForEach(section.rows) { row in
                                self.paragraphRow(row)
                            }
                        } header: {
                            if let chapter = section.chapter {
                                self.chapterHeader(chapter, isCurrent: chapter.startTimeMs == self.currentChapterStartMs)
                            }
                        }
                    }

                    Spacer().frame(height: self.style.bottomInset)
                }
                .padding(.trailing, 8)
            }
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting:
                    self.beginUserScroll()
                case .decelerating:
                    self.scheduleScrollResume(proxy: proxy)
                default:
                    break
                }
            }
            .onChange(of: self.currentTimeMs) { _, newTimeMs in
                self.syncCurrentLine(using: newTimeMs, proxy: proxy, animate: !self.userIsScrolling)
            }
            .onChange(of: self.transcript) { _, _ in
                self.syncCurrentLine(using: self.currentTimeMs, proxy: proxy, animate: false)
            }
            .onAppear {
                self.syncCurrentLine(using: self.currentTimeMs, proxy: proxy, animate: false)
                if let currentLineId = self.currentLineId {
                    Task { @MainActor in
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(currentLineId, anchor: .center)
                    }
                }
            }
            .onDisappear {
                self.scrollResumeTask?.cancel()
                self.hoveredLineId = nil
            }
        }
    }

    /// Transcript rows grouped under the episode's chapters.
    private var sections: [PodcastTranscriptSection] {
        PodcastTranscriptSection.sections(
            chapters: self.transcript.chapters,
            lines: self.transcript.lines
        )
    }

    /// Start time of the chapter being listened to, used to mark the current heading.
    private var currentChapterStartMs: Int? {
        self.transcript.chapters.last(where: { $0.startTimeMs <= self.currentTimeMs })?.startTimeMs
    }

    /// One transcript paragraph, with the emphasis of the paragraph being spoken.
    private func paragraphRow(_ row: PodcastTranscriptRow) -> some View {
        let isCurrent = row.lineIndex == self.currentLineIndex
        let isSpoken = self.isSpoken(row.lineIndex)
        let isHovered = self.hoveredLineId == row.id

        // Emphasis rides on opacity and a scale transform, never on the font itself: changing
        // the weight (or animating between weights) re-flows the paragraph, so words jump
        // between wrap points while the spoken paragraph moves. A scale effect redraws the
        // same layout — the technique the fullscreen synced lyrics use.
        return Text(row.line.text)
            .font(.system(size: self.style.fontSize, weight: self.style.weight))
            .foregroundStyle(self.style.textColor)
            .lineSpacing(self.style.lineSpacing)
            .opacity(self.opacity(isCurrent: isCurrent, isSpoken: isSpoken, isHovered: isHovered))
            .scaleEffect(self.scale(isCurrent: isCurrent, isSpoken: isSpoken, isHovered: isHovered), anchor: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { isHovered in
                self.hoveredLineId = isHovered ? row.id : nil
            }
            .onTapGesture {
                self.currentLineIndex = row.lineIndex
                self.currentLineId = row.id
                self.onSeek(row.line.timeInMs)
            }
            .animation(.easeInOut(duration: 0.35), value: self.currentLineIndex)
            .animation(.easeOut(duration: 0.16), value: self.hoveredLineId)
            .id(row.id)
    }

    /// A chapter heading that seeks to the start of its section when clicked.
    private func chapterHeader(_ chapter: PodcastChapter, isCurrent: Bool) -> some View {
        Button {
            HapticService.toggle()
            self.onSeek(chapter.startTimeMs)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: self.style.chapterFontSize - 2, weight: .semibold))
                    .foregroundStyle(self.style.textColor.opacity(isCurrent ? 0.85 : 0.45))

                Text(chapter.title)
                    .font(.system(size: self.style.chapterFontSize, weight: .semibold))
                    .foregroundStyle(
                        self.style.textColor.opacity(isCurrent ? 0.95 : self.style.chapterOpacity)
                    )
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(self.chapterTime(chapter.startTimeMs))
                    .font(.system(size: self.style.chapterFontSize - 1, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(self.style.textColor.opacity(isCurrent ? 0.7 : 0.4))
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Pinned headings sit over the paragraphs scrolling underneath, so they need a scrim.
        .background(self.style.chapterHeaderBackground)
        .animation(.easeInOut(duration: 0.3), value: isCurrent)
        .help(String(localized: "Play from Chapter"))
        .accessibilityIdentifier(self.style.chapterHeaderIdentifier)
        .accessibilityLabel(chapter.title)
    }

    private func chapterTime(_ timeMs: Int) -> String {
        let totalSeconds = max(0, timeMs / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func isSpoken(_ index: Int) -> Bool {
        guard let currentLineIndex else { return false }
        return index < currentLineIndex
    }

    private func opacity(isCurrent: Bool, isSpoken: Bool, isHovered: Bool) -> Double {
        if isCurrent {
            return self.style.currentOpacity
        }
        if isHovered {
            return self.style.hoveredOpacity
        }
        return isSpoken ? self.style.spokenOpacity : self.style.upcomingOpacity
    }

    /// Render-only emphasis transform, mirroring the fullscreen synced lyrics lines so paragraph
    /// layout never changes while playback moves through the transcript.
    private func scale(isCurrent: Bool, isSpoken: Bool, isHovered: Bool) -> CGFloat {
        if isCurrent {
            return 1
        }
        if isHovered {
            return 0.985
        }
        return isSpoken ? 0.95 : 0.965
    }

    private func beginUserScroll() {
        self.userIsScrolling = true
        self.resumeScrollGeneration += 1
        self.scrollResumeTask?.cancel()
    }

    /// Re-enables following the spoken paragraph after the user stops scrolling.
    private func scheduleScrollResume(proxy: ScrollViewProxy) {
        let generation = self.resumeScrollGeneration
        self.scrollResumeTask?.cancel()
        self.scrollResumeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, generation == self.resumeScrollGeneration else { return }
            self.userIsScrolling = false
            guard let currentLineId = self.currentLineId else { return }
            withAnimation(.easeInOut(duration: 0.42)) {
                proxy.scrollTo(currentLineId, anchor: .center)
            }
        }
    }

    private func syncCurrentLine(using timeMs: Int, proxy: ScrollViewProxy, animate: Bool) {
        let newIndex = self.transcript.lines.lastIndex(where: { $0.timeInMs <= timeMs })

        guard let newIndex else {
            // Playback has not reached the first paragraph yet.
            self.currentLineIndex = nil
            self.currentLineId = nil
            return
        }

        let newId = self.transcript.lines[newIndex].id
        guard newId != self.currentLineId else { return }

        self.currentLineIndex = newIndex
        self.currentLineId = newId
        guard !self.userIsScrolling else { return }

        if animate {
            withAnimation(.easeInOut(duration: 0.42)) {
                proxy.scrollTo(newId, anchor: .center)
            }
        } else {
            proxy.scrollTo(newId, anchor: .center)
        }
    }
}
