import AppKit
import SwiftUI

// MARK: - PlayerBar

/// Player bar shown at the bottom of the content area, styled like Apple Music with Liquid Glass.
///
/// Every page attaches its own, with `safeAreaInset(edge: .bottom)`, and that inset belongs **inside** the
/// page's `NavigationStack` — applied to the stack itself it belongs to the stack's container instead, so
/// it outlives a push while the destination page brings a bar of its own, and the reader sees two bars
/// stacked one above the other. Measured in a reproduction of the two arrangements: with the inset inside
/// the stack a push renders one bar, with it outside, two.
@available(macOS 26.0, *)
struct PlayerBar: View {
    private static let brandAccent = PackageResourceLookup.brandAccent

    /// The bar's height, and the height of the capsule its glass — and its loading wash — are drawn in.
    private static let height: CGFloat = 52

    @Environment(PlayerService.self) private var playerService
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(LibraryViewModel.self) private var libraryViewModel: LibraryViewModel?

    /// Namespace for glass effect morphing and unioning.
    @Namespace private var playerNamespace

    /// How long the expanded seek bar takes to arrive and to fold away again.
    private static let revealAnimation = Animation.easeInOut(duration: 0.15)
    /// How wide the scrubber would like to be, and how much bar is left for the ends it does not cover.
    ///
    /// A scrubber is only worth summoning if it is long enough to aim at — 460pt is roughly a third of a
    /// wide window's bar and the length a slider wants — but never at the cost of the buttons that stay
    /// outside it: `scrubberEndRoom` is what the transport controls on the left and the actions, volume
    /// and fullscreen on the right keep, and the scrubber takes what is left on either side of the title.
    private static let preferredScrubberWidth: CGFloat = 460
    private static let scrubberEndRoom: CGFloat = 92
    /// Below this the scrubber stops being a scrubber, so a bar squeezed into a very narrow pane gives
    /// it this and lets the space at the ends go rather than growing it down to a sliver again.
    private static let minimumScrubberWidth: CGFloat = 240
    /// How far the controls the scrubber covers fade out at either end of it. This is the gradient the
    /// row dissolves into, and the reason a covered control is faded and not clipped: an edge would give
    /// the scrubber a surface of its own to sit on, and it is meant to be a part of the bar.
    private static let dissolveRamp: CGFloat = 26

    /// The bar's controls row, and the track info inside it, as measured off the layout: the row is what
    /// the scrubber is sized against (it spans the bar minus its insets) and the title is what it is
    /// centred on. Both are read in `.global`, as they are only ever compared with each other.
    @State private var controlsFrame: CGRect = .zero
    @State private var titleFrame: CGRect = .zero

    /// Whether the pointer is resting on the bar's track info.
    ///
    /// The track info is the bar's **only** hover hotspot: the expanded seek bar is a large layer to
    /// put under the pointer, so the pointer opts into it by resting on the track it seeks in, rather
    /// than by being anywhere on the bar at all.
    @State private var isHoveringTrackInfo = false

    /// Whether the pointer is on the expanded seek bar itself.
    ///
    /// Once the layer is up the pointer is over the *slider*, which is far wider than the track info it
    /// came from; without this the bar would fold the slider away from under the hand dragging it.
    @State private var isHoveringExpandedSeekBar = false

    /// Local seek value for smooth slider dragging without network calls on every change.
    @State private var seekValue: Double = 0
    @State private var isSeeking = false

    /// Local volume value for smooth slider dragging.
    @State private var volumeValue: Double = 1.0
    @State private var isAdjustingVolume = false

    /// Cached formatted progress string to avoid repeated formatting.
    @State private var formattedProgress: String = "0:00"
    @State private var formattedRemaining: String = "-0:00"
    /// Last integer second of progress to reduce string formatting frequency.
    @State private var lastProgressSecond: Int = -1

    var body: some View {
        // TEMPORARY: scroll diagnostics (see PerfHUD).
        if PerfHUD.isEnabled, !PerfHUD.shared.showsPlayerBar {
            EmptyView()
        } else {
            self.barBody
        }
    }

    private var barBody: some View {
        GlassEffectContainer(spacing: 0) {
            ZStack(alignment: .leading) {
                // Under the controls, over the glass: the bar's own capsule is what the wash is masked
                // to, so the bar itself looks busy and nothing the user is reaching for is covered.
                self.loadingWash

                HStack(spacing: 0) {
                    // Left section: Playback controls
                    self.playbackControls

                    Spacer()

                    // Center section: Track info — and the hotspot the seek bar is summoned from
                    self.centerSection

                    Spacer()

                    // Right section: Volume control
                    self.volumeControl
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                // Measured before the mask is applied, so the frame is the row's own; the bar's width is
                // read off it (the row spans the bar minus its insets) rather than measured separately.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    self.controlsFrame = frame
                }
                // The controls the scrubber has grown over are **dissolved, not covered**: no surface is
                // laid on the bar for the scrubber to sit on — the bar's own glass is what shows behind it
                // — and the row fades out over a gradient across the scrubber's span, so what goes with it
                // goes softly. See `controlsMask`.
                .mask(self.controlsMask)
            }
            // Pinned here rather than on the controls: the wash is a flexible layer, and an inset's
            // content is offered a tall proposal, which without this it would take.
            .frame(height: Self.height)
            // The seek bar is a *layer above* the bar rather than a column in it, which is what lets it
            // be a scrubber with something to grab — as wide as the bar can afford to lend it — instead
            // of the sliver the buttons either side of it left over. An overlay is offered the bar's size
            // and cannot give one back, so the slider's width is never the bar's minimum and hovering can
            // no longer widen the pane: the middle column it used to be had to be laid out in both hover
            // states for exactly that reason, and paid for it with a slider too small to drag.
            .overlay {
                if self.showsExpandedSeekBar {
                    self.expandedSeekBar
                }
            }
            .modifier(PlayerBarGlassModifier(namespace: self.playerNamespace))
            .animation(AppAnimation.standard, value: self.playerService.playerBarLoading)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background {
            // Keyboard shortcuts for media controls.
            //
            // Deliberately re-enabled while the fullscreen overlay hides and disables this bar: these key
            // equivalents are the window's media controls, and the overlay disables the whole subtree it
            // covers (which is what resigns focus so no hidden control can be activated). `allowsHitTesting`
            // keeps these invisible buttons unclickable while they are covered.
            Group {
                // Space: Play/Pause
                Button("") {
                    Task { await self.playerService.playPause() }
                }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)

                // Command + Right Arrow: Next track, or forward 30s for a podcast episode
                Button("") {
                    if self.playerService.isCurrentTrackPodcast {
                        Task { await self.seek(by: 30) }
                    } else {
                        Task { await self.playerService.next() }
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(self.playerService.currentEpisode != nil)
                .opacity(0)

                // Command + Left Arrow: Previous track, or back 15s for a podcast episode
                Button("") {
                    if self.playerService.isCurrentTrackPodcast {
                        Task { await self.seek(by: -15) }
                    } else {
                        Task { await self.playerService.previous() }
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(self.playerService.currentEpisode != nil)
                .opacity(0)

                // Command + Up Arrow: Volume up
                Button("") {
                    Task { await self.playerService.setVolume(min(1.0, self.playerService.volume + 0.1)) }
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .opacity(0)

                // Command + Down Arrow: Volume down
                Button("") {
                    Task { await self.playerService.setVolume(max(0.0, self.playerService.volume - 0.1)) }
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .opacity(0)
            }
            .disabled(false)
        }
        .onChange(of: self.playerService.progress) { _, newValue in
            // Sync local seek value when not actively seeking
            if !self.isSeeking, self.playerService.duration > 0 {
                self.seekValue = newValue / self.playerService.duration
            }
            // Only update formatted strings when the second changes to reduce Text view updates
            let currentSecond = Int(newValue)
            if currentSecond != self.lastProgressSecond {
                self.lastProgressSecond = currentSecond
                self.formattedProgress = self.formatTime(newValue)
                self.formattedRemaining = "-\(self.formatTime(self.playerService.duration - newValue))"
            }
        }
        .onChange(of: self.playerService.volume) { _, newValue in
            // Sync local volume value when not actively adjusting
            if !self.isAdjustingVolume {
                self.volumeValue = newValue
            }
        }
        .onAppear {
            // Sync local volume value from saved state on initial load
            self.volumeValue = self.playerService.volume
        }
    }

    // MARK: - Loading Wash

    /// The wash shown while the WebView is loading a page or bringing a track up.
    ///
    /// It fills the bar's glass capsule end to end and sits *under* the controls, so it never covers a
    /// button or the track it is loading: the whole bar takes on a light grey that deepens as the page
    /// comes in, which is the feedback and all of it. The capsule it is masked to is the same one the
    /// glass is drawn in, so the two cannot drift apart.
    @ViewBuilder
    private var loadingWash: some View {
        if let indicator = self.playerService.playerBarLoading {
            PlayerBarLoadingWash(indicator: indicator)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: - Center Section (the track info, and the seek bar's hotspot)

    /// The track info at rest, and the hotspot the expanded seek bar is summoned from.
    ///
    /// A hotspot spans the track info's whole frame, not just the glyphs in it, so it is one rectangle
    /// that reads as "the track that is playing" rather than a text run the pointer has to find. It is
    /// deliberately no wider than that: the seek bar is a layer over the bar, so the pointer asks for it
    /// from the track, and only from the track.
    private var centerSection: some View {
        Group {
            // Error state display with retry option
            if case let .error(message) = playerService.state {
                self.errorView(message: message)
            } else {
                self.trackInfoView
                    .contentShape(.rect)
                    .onHover { hovering in
                        withAnimation(Self.revealAnimation) {
                            self.isHoveringTrackInfo = hovering
                        }
                    }
            }
        }
        .frame(maxWidth: 400)
        // Where the title sits, which is not the bar's middle: the scrubber is aligned to *this*, so the
        // pointer that asked for it from the track finds it under the track and not wherever the bar's
        // centre happens to be.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            self.titleFrame = frame
        }
    }

    /// Whether the seek bar — or, on a live stream, the LIVE badge — is expanded over the bar.
    ///
    /// True while the pointer is on the track info or on the layer it summoned, and for as long as a
    /// seek is in flight — a drag can leave both behind, and the slider going away under the pointer
    /// mid-drag is the one thing this must never do.
    private var showsExpandedSeekBar: Bool {
        guard self.playerService.currentTrack != nil else { return false }
        // A bar that failed and is offering Retry is not a scrubber: its middle belongs to the message.
        if case .error = self.playerService.state { return false }
        return self.isHoveringTrackInfo || self.isHoveringExpandedSeekBar || self.isSeeking
    }

    // MARK: - Expanded Seek Bar (the scrubber laid over the bar, aligned to the title)

    /// The seek bar — or, for a live stream, the LIVE badge — laid over the bar, aligned to the title.
    ///
    /// It is a scrubber, not a second bar: it takes the width the bar can lend around the track info (see
    /// ``scrubberWidth``) and sits where that track info is, rather than filling the bar or centring itself
    /// on it. The buttons it does not reach — the transport on the left, the actions, volume and fullscreen
    /// on the right — keep both their places and their clicks, which is the point of leaving the ends alone.
    ///
    /// It has no surface of its own: what it covers is dissolved out of the row instead (`controlsMask`),
    /// so the bar keeps its own glass and the scrubber reads as the bar becoming a scrubber rather than as
    /// a pill dropped on the bar — which is what it looked like with one, whatever the pill was made of.
    ///
    /// It arrives by growing out of the track info (`scale` from a little over half its width, about what
    /// the title is), so the reader watches it come rather than finding it there.
    @ViewBuilder
    private var expandedSeekBar: some View {
        if self.playerService.isCurrentItemLive {
            self.liveIndicatorView
                .offset(x: self.titleOffsetFromBarCentre)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // A label, not a target: the controls stay reachable underneath it.
                .allowsHitTesting(false)
                .transition(.opacity)
        } else if self.scrubberWidth > 0 {
            self.seekBarView
                .frame(width: self.scrubberWidth, height: Self.height)
                // The capsule is the whole scrubber's shape, not just the slider's: everything it covers is
                // the scrubber's to answer for, so a click on a dissolved button cannot get past it.
                .contentShape(.capsule)
                // Hover is this view's own shape too, which is what lets the pointer leave it for a button
                // at either end and get that button back without the scrubber staying up over it.
                .onHover { hovering in
                    withAnimation(Self.revealAnimation) {
                        self.isHoveringExpandedSeekBar = hovering
                    }
                }
                // Anchored to the title rather than to the bar: it is the track's scrubber, and the title
                // is only the bar's middle when the controls either side of it are the same width.
                .offset(x: self.titleOffsetFromBarCentre)
                .transition(.scale(scale: 0.55).combined(with: .opacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// How far the title sits from the bar's centre — where the scrubber is centred, and how wide it may be.
    private var titleOffsetFromBarCentre: CGFloat {
        self.titleFrame.midX - self.controlsFrame.midX
    }

    /// The bar's own width, read off the controls row, which spans it minus its insets.
    private var barWidth: CGFloat {
        self.controlsFrame.width + 40
    }

    /// How wide the scrubber is where the bar can afford it.
    ///
    /// It grows about the *track info*, so what it needs is not the bar's width but the room from the title
    /// to the nearer end of the bar — half of the bar on a bar whose controls are even either side of it,
    /// and less when they are not (the actions and volume take more than the transport does). Zero until the
    /// row has been measured, which is what keeps it off the bar until there is a width to give it.
    private var scrubberWidth: CGFloat {
        guard self.controlsFrame.width > 0, self.titleFrame.width > 0 else { return 0 }
        let roomToEnd = self.barWidth / 2 - abs(self.titleOffsetFromBarCentre)
        let roomy = min(Self.preferredScrubberWidth, 2 * (roomToEnd - Self.scrubberEndRoom))
        // `roomToEnd` also caps it: a scrubber wider than the room about the title would hang off the bar.
        return min(max(Self.minimumScrubberWidth, roomy), 2 * roomToEnd - 16)
    }

    /// What is left of the bar's controls once the scrubber has grown over them.
    ///
    /// A mask, so the row keeps its layout — and with it the bar's footprint and the pane's width — while
    /// the controls under the scrubber fade out rather than being cut out. Black is shown, clear is hidden,
    /// and the two gradients at either end of the clear span are what make the dissolve a gradient: only
    /// the span's core is fully gone, so a button the scrubber only half reaches is half there, which is
    /// what the pointer sees as it arrives.
    private var controlsMask: some View {
        let ramp = self.showsExpandedSeekBar ? Self.dissolveRamp : 0
        let core = self.showsExpandedSeekBar ? self.scrubberWidth - ramp * 2 : 0
        // Where the span starts, in the row's own coordinates. It is placed by its leading edge rather than
        // by its width, so it grows out from the title on both sides as the width animates.
        let leading = self.titleFrame.midX - self.scrubberWidth / 2 - self.controlsFrame.minX
        return HStack(spacing: 0) {
            Color.black.frame(width: max(0, leading))
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: ramp)
            Color.clear.frame(width: max(0, core))
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: ramp)
            Color.black
        }
    }

    // MARK: - Live Indicator View (replaces seek bar for live streams)

    private var liveIndicatorView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)

            Text("LIVE", comment: "Label shown on the player bar when playing a live radio stream")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
                .tracking(0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Live stream"))
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))

            Text(message)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Button {
                Task {
                    if let track = playerService.currentTrack {
                        await self.playerService.play(song: track)
                    }
                }
            } label: {
                Text("Retry", comment: "Button to retry failed playback")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary)
            .clipShape(.capsule)
        }
    }

    // MARK: - Track Info View

    private var trackInfoView: some View {
        HStack(spacing: 10) {
            // Thumbnail
            CachedAsyncImage(
                url: self.playerService.currentTrack?.thumbnailURL?.highQualityThumbnailURL,
                fallbackURL: self.playerService.currentTrack?.thumbnailURL,
                identity: self.playerService.currentTrack?.videoId
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .overlay {
                        CassetteIcon(size: 20)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Track info
            if let track = playerService.currentTrack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Text(track.artistsDisplay.isEmpty ? String(localized: "Unknown Artist") : track.artistsDisplay)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 200, alignment: .leading)
            }
        }
    }

    // MARK: - Seek Bar View (the expanded seek bar's row)

    /// Elapsed time, the slider, remaining time — laid out inside the scrubber once it has grown into the
    /// space the bar lent it, rather than in whatever the buttons either side of the middle left over.
    ///
    /// The row is inset by exactly the dissolve's ramp, so the times and the ends of the slider sit on the
    /// part of the span the mask clears completely, rather than over a control that is still half there.
    private var seekBarView: some View {
        HStack(spacing: 12) {
            // Elapsed time - use cached formatted string when not seeking
            Text(self.isSeeking ? self.formatTime(self.seekValue * self.playerService.duration) : self.formattedProgress)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(minWidth: 45, alignment: .trailing)
                .monospacedDigit()

            // Seek slider
            Slider(value: self.$seekValue, in: 0 ... 1) { editing in
                if editing {
                    // User started dragging
                    self.isSeeking = true
                } else {
                    // User finished dragging - perform seek
                    self.performSeek()
                }
            }
            // Full size, unlike the volume slider: this is the bar's scrubber, and it now has the room
            // for a track and a knob the pointer can land on.
            .controlSize(.regular)
            .tint(Self.brandAccent)
            .accessibilityIdentifier(AccessibilityID.PlayerBar.seekSlider)
            .accessibilityLabel(String(localized: "Playback Position"))

            // Remaining time - use cached formatted string when not seeking
            Text(self.isSeeking ? "-\(self.formatTime(self.playerService.duration - self.seekValue * self.playerService.duration))" : self.formattedRemaining)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(minWidth: 45, alignment: .leading)
                .monospacedDigit()
        }
        .padding(.horizontal, Self.dissolveRamp)
    }

    /// Performs the actual seek operation after slider interaction ends.
    private func performSeek() {
        guard self.isSeeking else { return }
        let seekTime = self.seekValue * self.playerService.duration
        Task {
            await self.playerService.seek(to: seekTime)
            self.isSeeking = false
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        } else {
            return String(format: "%d:%02d", mins, secs)
        }
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        HStack(spacing: 16) {
            // Shuffle
            Button {
                HapticService.toggle()
                self.playerService.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.playerService.shuffleEnabled ? .red : .primary.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(String(localized: "Shuffle"))
            .accessibilityValue(self.playerService.shuffleEnabled ? String(localized: "On") : String(localized: "Off"))

            // Previous track, or back 15 seconds while a podcast episode is playing.
            //
            // `isCurrentTrackPodcast` — not `currentEpisode` — is the signal here: a podcast played
            // from a show page is a queued `Song` with the "podcast" artist marker and leaves
            // `currentEpisode` nil. `currentEpisode` is set only for standalone artist-page episodes
            // (live streams), which have no duration and therefore keep the track controls disabled.
            if self.playerService.isCurrentTrackPodcast {
                self.skipButton(seconds: -15, systemImage: "gobackward.15")
            } else {
                Button {
                    HapticService.playback()
                    Task {
                        await self.playerService.previous()
                    }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.pressable)
                .disabled(self.playerService.currentEpisode != nil)
                .accessibilityLabel(String(localized: "Previous track"))
            }

            // Play/Pause
            Button {
                HapticService.playback()
                Task {
                    await self.playerService.playPause()
                }
            } label: {
                Image(systemName: self.playerService.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .glassEffectID("playPause", in: self.playerNamespace)
            .accessibilityLabel(self.playerService.isPlaying ? String(localized: "Pause") : String(localized: "Play"))

            // Next track, or forward 30 seconds while a podcast episode is playing.
            if self.playerService.isCurrentTrackPodcast {
                self.skipButton(seconds: 30, systemImage: "goforward.30")
            } else {
                Button {
                    HapticService.playback()
                    Task {
                        await self.playerService.next()
                    }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.pressable)
                .disabled(self.playerService.currentEpisode != nil)
                .accessibilityLabel(String(localized: "Next track"))
            }

            // Repeat
            Button {
                HapticService.toggle()
                self.playerService.cycleRepeatMode()
            } label: {
                Image(systemName: self.repeatIcon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.playerService.repeatMode != .off ? .red : .primary.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(String(localized: "Repeat"))
            .accessibilityValue(self.repeatAccessibilityValue)
        }
    }

    /// A rewind/forward button used in place of the previous/next controls while a podcast
    /// episode is playing, mirroring the transport row of the fullscreen podcast view.
    private func skipButton(seconds: Int, systemImage: String) -> some View {
        Button {
            HapticService.playback()
            Task {
                await self.seek(by: seconds)
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.pressable)
        .disabled(self.playerService.duration <= 0)
        .accessibilityLabel(
            seconds < 0
                ? String(localized: "Back 15 Seconds")
                : String(localized: "Forward 30 Seconds")
        )
    }

    /// Seeks relative to the current position, clamped to the episode's bounds.
    private func seek(by seconds: Int) async {
        guard self.playerService.duration > 0 else { return }
        let target = max(0, min(self.playerService.duration, self.playerService.progress + Double(seconds)))
        await self.playerService.seek(to: target)
    }

    private var repeatIcon: String {
        switch self.playerService.repeatMode {
        case .off, .all:
            "repeat"
        case .one:
            "repeat.1"
        }
    }

    private var repeatAccessibilityValue: String {
        switch self.playerService.repeatMode {
        case .off:
            String(localized: "Off")
        case .all:
            String(localized: "All")
        case .one:
            String(localized: "One")
        }
    }

    // MARK: - Volume Control

    private var volumeControl: some View {
        HStack(spacing: 8) {
            // Like/Dislike/Library actions
            self.actionButtons


            Divider()
                .frame(height: 20)
                .padding(.horizontal, 4)

            Image(systemName: self.volumeIcon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 18)

            // Volume slider with immediate updates
            Slider(value: self.$volumeValue, in: 0 ... 1) { editing in
                if editing {
                    // User started dragging
                    self.isAdjustingVolume = true
                } else {
                    // User finished dragging/clicking - apply volume change
                    self.isAdjustingVolume = false
                    // Always apply volume when interaction ends to ensure WebView is synced
                    Task {
                        await self.playerService.setVolume(self.volumeValue)
                    }
                }
            }
            .frame(width: 80)
            .controlSize(.small)
            .tint(Self.brandAccent)
            .onChange(of: self.volumeValue) { oldValue, newValue in
                // Apply volume changes in real-time during dragging for immediate feedback
                if self.isAdjustingVolume {
                    // Haptic feedback at slider boundaries
                    if (oldValue > 0 && newValue == 0) || (oldValue < 1 && newValue == 1) {
                        HapticService.sliderBoundary()
                    }
                    Task {
                        await self.playerService.setVolume(newValue)
                    }
                }
            }
            

            // Cast button
            CastButton()
        }
    }

    // MARK: - Action Buttons (Like/Dislike/Lyrics/Queue)

    private var actionButtons: some View {
        @Bindable var player = self.playerService

        return HStack(spacing: 12) {
            // Dislike button
            Button {
                HapticService.toggle()
                self.playerService.dislikeCurrentTrack()
            } label: {
                Image(systemName: self.playerService.currentTrackLikeStatus == .dislike
                    ? "hand.thumbsdown.fill"
                    : "hand.thumbsdown")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.playerService.currentTrackLikeStatus == .dislike ? .red : .primary.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .symbolEffect(.bounce, value: self.playerService.currentTrackLikeStatus == .dislike)
            .accessibilityLabel(String(localized: "Dislike"))
            .accessibilityValue(self.playerService.currentTrackLikeStatus == .dislike ? String(localized: "Disliked") : String(localized: "Not disliked"))
            .disabled(self.playerService.currentTrack == nil)

            // Like button
            Button {
                HapticService.toggle()
                self.playerService.likeCurrentTrack()
            } label: {
                Image(systemName: self.playerService.currentTrackLikeStatus == .like
                    ? "hand.thumbsup.fill"
                    : "hand.thumbsup")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.playerService.currentTrackLikeStatus == .like ? .red : .primary.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .symbolEffect(.bounce, value: self.playerService.currentTrackLikeStatus == .like)
            .accessibilityLabel(String(localized: "Like"))
            .accessibilityValue(self.playerService.currentTrackLikeStatus == .like ? String(localized: "Liked") : String(localized: "Not liked"))
            .disabled(self.playerService.currentTrack == nil)


            // Add to Playlist button
            if let currentTrack = self.playerService.currentTrack,
               let client = self.libraryViewModel?.client ?? self.playerService.ytMusicClient
            {
                AddToPlaylistPopoverButton(
                    song: currentTrack,
                    client: client,
                    libraryViewModel: self.libraryViewModel,
                    preferredLikeStatus: self.playerService.currentTrackLikeStatus,
                    icon: "plus.circle",
                    iconSize: 15,
                    usePressableStyle: true
                )
                .accessibilityLabel(String(localized: "Add to Playlist"))
            }

            if !self.playerService.showFullscreenNowPlaying {
                // Lyrics button
                Button {
                    HapticService.toggle()
                    withAnimation(AppAnimation.standard) {
                        if self.playerService.isNowPlayingSidebarEnabled {
                            self.playerService.toggleNowPlayingSidebar(page: .lyrics)
                        } else {
                            player.showLyrics.toggle()
                        }
                    }
                } label: {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(self.playerService.isLyricsPanelActive ? .red : .primary.opacity(0.85))
                }
                .buttonStyle(.pressable)
                .glassEffectID("lyrics", in: self.playerNamespace)
                .accessibilityIdentifier(AccessibilityID.PlayerBar.lyricsButton)
                .accessibilityLabel(String(localized: "Lyrics"))
                .accessibilityValue(self.playerService.isLyricsPanelActive ? String(localized: "Showing") : String(localized: "Hidden"))

                // Queue button
                Button {
                    HapticService.toggle()
                    withAnimation(AppAnimation.standard) {
                        if self.playerService.isNowPlayingSidebarEnabled {
                            self.playerService.toggleNowPlayingSidebar(page: .queue)
                        } else {
                            player.showQueue.toggle()
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(self.playerService.isQueuePanelActive ? .red : .primary.opacity(0.85))
                }
                .buttonStyle(.pressable)
                .glassEffectID("queue", in: self.playerNamespace)
                .accessibilityIdentifier(AccessibilityID.PlayerBar.queueButton)
                .accessibilityLabel(String(localized: "Queue"))
                .accessibilityValue(self.playerService.isQueuePanelActive ? String(localized: "Showing") : String(localized: "Hidden"))

            }

            // Fullscreen now-playing button
            Button {
                HapticService.toggle()
                DiagnosticsLogger.player.debug(
                    "Fullscreen button clicked, toggling showFullscreenNowPlaying from \(self.playerService.showFullscreenNowPlaying)"
                )
                withAnimation(AppAnimation.standard) {
                    player.showFullscreenNowPlaying.toggle()
                }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.playerService.showFullscreenNowPlaying ? .red : .primary.opacity(0.85))
            }
            .buttonStyle(.pressable)
            .glassEffectID("fullscreenNowPlaying", in: self.playerNamespace)
            .accessibilityIdentifier(AccessibilityID.PlayerBar.videoButton)
            .accessibilityLabel(
                self.playerService.isCurrentTrackPodcast
                    ? String(localized: "Fullscreen Podcast")
                    : String(localized: "Fullscreen Now Playing")
            )
            .help(
                self.playerService.isCurrentTrackPodcast
                    ? String(localized: "Fullscreen Podcast")
                    : String(localized: "Fullscreen Now Playing")
            )
            .accessibilityValue(self.playerService.showFullscreenNowPlaying ? String(localized: "On") : String(localized: "Off"))
        }
    }

    private var volumeIcon: String {
        let currentVolume = self.isAdjustingVolume ? self.volumeValue : self.playerService.volume
        if currentVolume == 0 {
            return "speaker.slash.fill"
        } else if currentVolume < 0.5 {
            return "speaker.wave.1.fill"
        } else {
            return "speaker.wave.2.fill"
        }
    }
}

// MARK: - PlayerBarGlassModifier

/// TEMPORARY: applies the player bar's Liquid Glass treatment unless the PerfHUD turned it off
/// to test whether backdrop sampling over the scrolling list is what caps the frame rate.
@available(macOS 26.0, *)
private struct PlayerBarGlassModifier: ViewModifier {
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if PerfHUD.isEnabled, !PerfHUD.shared.usesGlass {
            content
        } else {
            content
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("playerBar", in: self.namespace)
        }
    }
}

@available(macOS 26.0, *)
#Preview {
    PlayerBar()
        .environment(PlayerService())
        .environment(WebKitManager.shared)
        .environment(CastService())
        .frame(width: 600)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}
