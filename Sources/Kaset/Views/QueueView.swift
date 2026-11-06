import SwiftUI

// MARK: - QueueView

/// Right sidebar panel displaying the playback queue.
@available(macOS 26.0, *)
struct QueueView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(LibraryViewModel.self) private var libraryViewModel: LibraryViewModel?
    @Environment(\.showCommandBar) private var showCommandBar

    /// Whether the user has manually scrolled (pauses auto-scroll).
    @State private var userIsScrolling = false
    /// Timer task to resume auto-scroll after user interaction.
    @State private var scrollResumeTask: Task<Void, Never>?

    /// Namespace for glass effect morphing.
    @Namespace private var queueNamespace

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 0) {
                // Header
                self.headerView

                Divider()
                    .opacity(0.3)

                // Automix tuning row, when the server offers tunings for the playing queue
                if !self.playerService.queueTunerChips.isEmpty {
                    QueueTunerChipsView(
                        chips: self.playerService.queueTunerChips,
                        isLoading: self.playerService.isApplyingQueueTuner,
                        onSelect: { chip in
                            Task {
                                await self.playerService.applyQueueTunerChip(chip)
                            }
                        }
                    )

                    Divider()
                        .opacity(0.3)
                }

                // Content
                self.contentView
            }
            .frame(width: 280)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
            .glassEffectID("queuePanel", in: self.queueNamespace)
        }
        .glassEffectTransition(.materialize)
        .accessibilityIdentifier(AccessibilityID.Queue.container)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Up Next")
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            // Clear queue button (only show if there are items beyond the current track)
            if self.playerService.queue.count > 1 {
                Button {
                    self.playerService.clearQueue()
                } label: {
                    Text("Clear")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.Queue.clearButton)
            }

            Button {
                self.playerService.toggleQueueDisplayMode()
            } label: {
                Label("Edit", systemImage: "square.and.pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .buttonBorderShape(.capsule)
            .help(String(localized: "Open queue in side panel"))
            .accessibilityLabel(String(localized: "Open queue in side panel"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        if self.playerService.queue.isEmpty {
            self.emptyQueueView
        } else {
            self.queueListView
        }
    }

    private var emptyQueueView: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text("No Queue")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Play songs from a playlist or album to build your queue.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(AccessibilityID.Queue.emptyState)
    }

    private var queueListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Rows are keyed by their queue entry rather than by position. Enumerating the
                    // queue allocated a copy of the whole array on every body evaluation, and offset
                    // identity made every row after a removal look like a brand-new row — the same
                    // two costs ADR-0014 removed from the playlist list.
                    ForEach(self.queueEntries) { entry in
                        if let header = self.sectionHeader(forRow: entry.index) {
                            self.sectionHeaderRow(
                                header,
                                clearsHandQueuedSongs: entry.index == self.playerService.manualQueueRange.lowerBound
                            )
                        }

                        QueueRowView(
                            song: entry.song,
                            index: entry.index,
                            isCurrentTrack: entry.index == self.playerService.currentIndex,
                            isPlaying: self.playerService.isPlaying,
                            isAutoplayIndicatorVisible: self.playerService.isYouTubeAutoplayIndicatorVisible,
                            isScrolling: self.userIsScrolling,
                            playerService: self.playerService,
                            client: self.libraryViewModel?.client,
                            libraryViewModel: self.libraryViewModel,
                            onRemove: {
                                self.playerService.removeFromQueue(videoIds: Set([entry.song.videoId]))
                            },
                            onTap: {
                                Task {
                                    await self.playerService.playFromQueue(at: entry.index)
                                }
                            }
                        )
                        .equatable()
                        .id(entry.id)
                        .accessibilityIdentifier(AccessibilityID.Queue.row(index: entry.index))
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            // The native scroll phases rather than a `simultaneousGesture`: a drag recognizer
            // competing with the scroll gesture is what this API exists to avoid. `.animating` is
            // the app's own scroll-to-current animation, so it is deliberately not read as the user
            // scrolling — that would pause auto-scroll during the very scroll it just performed.
            .onScrollPhaseChange { _, newPhase, _ in
                if newPhase == .interacting || newPhase == .decelerating {
                    self.userIsScrolling = true
                    self.scrollResumeTask?.cancel()
                } else if newPhase == .idle {
                    self.scrollResumeTask?.cancel()
                    self.scrollResumeTask = Task {
                        try? await Task.sleep(for: .seconds(8))
                        if !Task.isCancelled {
                            self.userIsScrolling = false
                        }
                    }
                }
            }
            .onAppear {
                self.scrollToCurrentSong(with: proxy, animated: false)
            }
            .onChange(of: self.playerService.currentIndex) { _, _ in
                guard !self.userIsScrolling else { return }
                self.scrollToCurrentSong(with: proxy, animated: true)
            }
            .onChange(of: self.userIsScrolling) { _, isScrolling in
                if !isScrolling {
                    self.scrollToCurrentSong(with: proxy, animated: true)
                }
            }
            .onDisappear {
                self.scrollResumeTask?.cancel()
            }
        }
        .accessibilityIdentifier(AccessibilityID.Queue.scrollView)
    }

    /// The queue as rows, each with an identity that survives a removal elsewhere in the queue.
    ///
    /// The same video can legitimately sit in the queue twice, so an occurrence count keeps those
    /// entries distinct without falling back to their position. Building this is a single pass of
    /// string and integer work, which is what it replaces — not a per-row view tree.
    private var queueEntries: [QueueEntry] {
        let queue = self.playerService.queue
        var occurrences: [String: Int] = [:]
        occurrences.reserveCapacity(queue.count)
        var entries: [QueueEntry] = []
        entries.reserveCapacity(queue.count)

        for (index, song) in queue.enumerated() {
            let occurrence = occurrences[song.videoId, default: 0]
            occurrences[song.videoId] = occurrence + 1
            entries.append(QueueEntry(id: "\(song.videoId)#\(occurrence)", song: song, index: index))
        }

        return entries
    }

    /// The caption that opens the section `row` belongs to, or `nil` for a row in the middle of one.
    ///
    /// Rows the reader added with "Add to Queue" are their own section under the playing row, the way
    /// Spotify's queue shows them; the playlist resumes in the section below.
    private func sectionHeader(forRow row: Int) -> String? {
        let run = self.playerService.manualQueueRange
        guard !run.isEmpty else { return nil }
        if row == run.lowerBound {
            return String(localized: "Next in queue")
        }
        if row == run.upperBound, row < self.playerService.queue.count {
            return String(localized: "Rest of the queue")
        }
        return nil
    }

    private func sectionHeaderRow(_ title: String, clearsHandQueuedSongs: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            if clearsHandQueuedSongs {
                Button {
                    self.playerService.clearManualQueue()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear Next in Queue"))
                .accessibilityLabel(String(localized: "Clear Next in Queue"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func scrollToCurrentSong(with proxy: ScrollViewProxy, animated: Bool) {
        guard self.queueEntries.indices.contains(self.playerService.currentIndex) else { return }
        // Rows are identified by their queue entry, so the current track is scrolled to by that id.
        let id = self.queueEntries[self.playerService.currentIndex].id

        if animated {
            withAnimation(.spring(duration: 0.45, bounce: 0.0)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

// MARK: - QueueRowView

@available(macOS 26.0, *)
private struct QueueRowView: View, Equatable {
    /// On-screen size of the row artwork; `ImageCache` doubles it for Retina. Without it the row
    /// decoded a 320×320 bitmap into a 40×40 slot, on the scroll path.
    static let thumbnailSize = CGSize(width: 40, height: 40)

    let song: Song
    let index: Int
    let isCurrentTrack: Bool
    let isPlaying: Bool
    let isAutoplayIndicatorVisible: Bool
    /// True while the panel is scrolling; suppresses hover highlighting.
    let isScrolling: Bool

    /// Services the row's menu needs. Held but not read here — the menu reads them in its own body,
    /// so a row does not subscribe the whole list to the player.
    let playerService: PlayerService
    let client: (any YTMusicClientProtocol)?
    let libraryViewModel: LibraryViewModel?

    let onRemove: () -> Void
    let onTap: () -> Void

    @State private var isHovering = false

    /// Compares only what the row draws. The closures and service references are excluded, which is
    /// sound because the menu reads live state and the actions are stateless.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.index == rhs.index
            && lhs.isCurrentTrack == rhs.isCurrentTrack
            && lhs.isPlaying == rhs.isPlaying
            && lhs.isAutoplayIndicatorVisible == rhs.isAutoplayIndicatorVisible
            && lhs.isScrolling == rhs.isScrolling
            && lhs.song.videoId == rhs.song.videoId
            && lhs.song.title == rhs.song.title
            && lhs.song.artistsDisplay == rhs.song.artistsDisplay
            && lhs.song.duration == rhs.song.duration
            && lhs.song.thumbnailURL == rhs.song.thumbnailURL
    }

    var body: some View {
        Button(action: self.onTap) {
            HStack(spacing: 12) {
                // Now Playing indicator or track number
                self.leadingIndicator
                    .frame(width: 24)

                // Thumbnail
                CachedAsyncImage(
                    url: self.song.thumbnailURL?.highQualityThumbnailURL,
                    fallbackURL: self.song.thumbnailURL,
                    targetSize: Self.thumbnailSize
                ) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .overlay {
                            CassetteIcon(size: 16)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                // Track info
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.song.title)
                        .font(.system(size: 13, weight: self.isCurrentTrack ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(self.isCurrentTrack ? .red : .primary)

                    HStack(spacing: 5) {
                        if self.isAutoplayIndicatorVisible {
                            Image(systemName: "sparkles")
                                .font(.system(size: 8, weight: .semibold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.14))
                                .foregroundStyle(.red)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .accessibilityLabel(String(localized: "Autoplay"))
                        }

                        Text(self.song.artistsDisplay.isEmpty ? String(localized: "Unknown Artist") : self.song.artistsDisplay)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Duration
                if let duration = song.duration {
                    Text(self.formatDuration(duration))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(self.backgroundColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.isHovering = hovering
        }
        .contextMenu {
            QueueRowMenuContent(
                song: self.song,
                isCurrentTrack: self.isCurrentTrack,
                playerService: self.playerService,
                client: self.client,
                libraryViewModel: self.libraryViewModel,
                onRemove: self.onRemove
            )
        }
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        if self.isCurrentTrack {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(self.isPlaying ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                .symbolEffect(
                    .variableColor.iterative,
                    options: .repeating,
                    isActive: self.isPlaying
                )
        } else {
            Text("\(self.index + 1)")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    private var backgroundColor: Color {
        if self.isCurrentTrack {
            return Color.red.opacity(0.1)
        } else if self.isHovering, !self.isScrolling {
            // A row passing under a stationary pointer during a flick must not swap its background.
            return Color.primary.opacity(0.05)
        }
        return .clear
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - QueueEntry

/// One row of the queue, with an identity that survives a removal elsewhere in the queue.
private struct QueueEntry: Identifiable {
    let id: String
    let song: Song
    let index: Int
}

// MARK: - QueueRowMenuContent

/// The queue row's context menu, as its own view so the player lookups happen when the menu is
/// presented rather than in every row's body.
@available(macOS 26.0, *)
private struct QueueRowMenuContent: View {
    let song: Song
    let isCurrentTrack: Bool
    let playerService: PlayerService
    let client: (any YTMusicClientProtocol)?
    let libraryViewModel: LibraryViewModel?
    let onRemove: () -> Void

    var body: some View {
        StartRadioContextMenu.menuItem(for: self.song, playerService: self.playerService)

        Divider()

        ShareContextMenu.menuItem(for: self.song)

        if let client = self.client {
            Divider()

            AddToPlaylistContextMenu(
                song: self.song,
                client: client,
                libraryViewModel: self.libraryViewModel
            )
        }

        if !self.isCurrentTrack {
            Button(role: .destructive) {
                self.onRemove()
            } label: {
                Label("Remove from Queue", systemImage: "minus.circle")
            }
        }
    }
}

@available(macOS 26.0, *)
#Preview("Queue View") {
    let playerService = PlayerService()
    QueueView()
        .environment(playerService)
        .frame(height: 600)
}

@available(macOS 26.0, *)
#Preview("Queue View with Items") {
    let playerService = PlayerService()
    // Note: In real use, queue would be populated via playQueue()
    QueueView()
        .environment(playerService)
        .frame(height: 600)
}
