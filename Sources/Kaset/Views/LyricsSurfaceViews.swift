import SwiftUI

// MARK: - LyricsClockReader

/// Draws a lyric sheet against the live playback clock, and keeps the clock stream to itself.
///
/// The position arrives from the hidden WebView's lyrics poll ten times a second
/// (`PlayerService.currentTimeMs`). A sheet needs it; the surface *around* a sheet does not — a
/// panel's glass, a column's artwork and cards, the fullscreen player's backdrop do not change with
/// playback — so the surface that read the stream itself was rebuilt ten times a second to hand a
/// sheet a number only the sheet uses.
///
/// This is the leaf that reads it. `Observation` tracks a property per view body, so the
/// invalidation stops here: the sheet is rebuilt with the position, and everything above it is left
/// alone. The fullscreen flag is read here for the same reason — whether the player is presented is
/// not a reason to rebuild the window behind it, and it is what tells a sheet it is covered.
@available(macOS 26.0, *)
struct LyricsClockReader<Content: View>: View {
    @Environment(PlayerService.self) private var playerService
    @ViewBuilder let content: (_ currentTimeMs: Int, _ isPlaying: Bool, _ isFullscreenPresented: Bool) -> Content

    var body: some View {
        self.content(
            self.playerService.currentTimeMs,
            self.playerService.isPlaying,
            self.playerService.showFullscreenNowPlaying
        )
    }
}

// MARK: - LyricsStateView

/// The state a lyric surface shows when it has no sheet to draw: loading, no track, or no lyrics.
///
/// Shared by the classic lyrics panel and the Now Playing sidebar so both state the same things the
/// same way — the same wording, the same icons, the same provider name — with `compact` shrinking the
/// type for the sidebar's three-line preview. Extracted from `LyricsView`; see ADR-0029.
@available(macOS 26.0, *)
struct LyricsStateView: View {
    /// Icon above the title, or `nil` while loading, when a progress indicator takes its place.
    let icon: String?
    let title: String
    let message: String?
    var isLoading = false
    /// Smaller type and spacing for the sidebar's preview.
    var compact = false

    var body: some View {
        VStack(spacing: self.compact ? 8 : 12) {
            if self.isLoading {
                // Pure SwiftUI spinner: the AppKit-backed `ProgressView` (`NSProgressIndicator`)
                // crashes when its `setFont:` invalidates intrinsic content size from inside
                // a layout pass re-entered by a mid-layout height change (crash 20:23 17.10).
                // This draws no AppKit view, so it cannot re-enter constraint resolution.
                SidebarSpinner(side: self.compact ? 16 : 20)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: self.compact ? 26 : 40))
                    .foregroundStyle(.tertiary)
            }

            Text(self.title)
                .font(self.compact ? .subheadline : .headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(self.compact ? .caption : .subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, self.compact ? 12 : 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - SidebarSpinner

/// Indeterminate spinner drawn with pure SwiftUI shapes (no `NSProgressIndicator`).
struct SidebarSpinner: View {
    var side: CGFloat = 20
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(.tertiary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: self.side, height: self.side)
            .rotationEffect(.degrees(self.spinning ? 360 : 0))
            .animation(
                .linear(duration: 0.9).repeatForever(autoreverses: false),
                value: self.spinning
            )
            .onAppear { self.spinning = true }
            .accessibilityLabel(String(localized: "Loading"))
    }
}

// MARK: - LyricsSearchingCaption

/// The caption a lyric surface shows while a lower-fidelity result is on screen and a better one may
/// still arrive from another provider.
///
/// The animation is left to the caller, which scopes it to this caption so a lyrics swap in the same
/// update is not animated along with it.
@available(macOS 26.0, *)
struct LyricsSearchingCaption: View {
    var onDark = false
    var horizontalPadding: CGFloat = 16
    var verticalPadding: CGFloat = 10

    var body: some View {
        ShimmerLine(text: String(localized: "Still searching for lyrics"), onDark: self.onDark)
            .padding(.horizontal, self.horizontalPadding)
            .padding(.vertical, self.verticalPadding)
            .transition(.lyricsSearchingCaption)
    }
}

// MARK: - LyricsSourceFooter

/// The sticky footer under a lyric sheet: which provider supplied the lyrics, the picker when it
/// offers more than one community version, and — for a surface that has no header of its own — the
/// control that re-runs the search.
///
/// Shared by the classic panel and the sidebar's expanded lyric page. The classic panel passes no
/// refresh action: its own header already carries one, and it is drawn by the panel it is in.
@available(macOS 26.0, *)
struct LyricsSourceFooter: View {
    @Environment(SyncedLyricsService.self) private var syncedLyricsService
    @Environment(\.openURL) private var openURL

    /// Whether the pointer is over the source line, which underlines the provider's name when it
    /// has a page to open. The line keeps its caption colour: the underline is the only change.
    @State private var isHoveringSource = false

    let source: String?
    /// Horizontal inset of the row. The classic panel sits inside a 280pt card; the sidebar is wider.
    var horizontalPadding: CGFloat = 16
    /// Re-runs the search that produced this sheet, or `nil` for a surface that keeps the control
    /// somewhere else. It sits at the trailing edge of the source row — the sheet's own bottom-right
    /// corner — rather than beside a title: refreshing means "search again for this song", which is
    /// what the source line already says about.
    var onRefresh: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.3)

            HStack(spacing: 8) {
                if let source {
                    Group {
                        if let url = self.songPageURL(for: source) {
                            Button {
                                self.openURL(url)
                            } label: {
                                Self.sourceLabel(source, underliningName: self.isHoveringSource)
                            }
                            .buttonStyle(.plain)
                            .onHover { self.isHoveringSource = $0 }
                            .help(String(localized: "Open this song on Unison"))
                            .accessibilityLabel(String(localized: "Source: Unison, opens on Unison"))
                        } else {
                            Self.sourceLabel(source, underliningName: false)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                self.variantPicker

                if let onRefresh {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Refresh lyrics"))
                    .accessibilityLabel(String(localized: "Refresh lyrics"))
                    .accessibilityIdentifier(AccessibilityID.NowPlayingSidebar.lyricsRefreshButton)
                }
            }
            .padding(.horizontal, self.horizontalPadding)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Source line

    /// The source line as one run of text, `Source:` and the provider's name, so it draws exactly
    /// as it did before the name could be a link. Only the name can be underlined.
    private static func sourceLabel(_ source: String, underliningName: Bool) -> Text {
        Text(verbatim: "Source: ") + Text(verbatim: self.sourceName(source))
            .underline(underliningName)
    }

    /// The provider's name on its own. Providers hand the footer their name, but the plain-text
    /// path spells the label into the string.
    private static func sourceName(_ source: String) -> String {
        let label = "Source:"
        guard source.hasPrefix(label) else { return source }
        return String(source.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
    }

    /// The page for the song on screen, when the provider that supplied the lyrics publishes one.
    /// Unison keys its song pages on the video id, which the service already holds for the sheet
    /// on display — including one served from the cache.
    private func songPageURL(for source: String) -> URL? {
        guard Self.sourceName(source) == UnisonProvider.displayName,
              let videoId = self.syncedLyricsService.currentLyricsVideoId,
              !videoId.isEmpty
        else { return nil }
        return UnisonProvider.songURL(videoId: videoId)
    }

    /// Menu for switching between the community versions the current provider offers, each with the
    /// community's verdict on it. Hidden unless there is more than one.
    @ViewBuilder
    private var variantPicker: some View {
        let variants = self.syncedLyricsService.availableLyricsVariants
        if variants.count > 1 {
            Menu {
                ForEach(variants) { variant in
                    Button {
                        self.syncedLyricsService.selectLyricsVariant(id: variant.id)
                    } label: {
                        if variant.id == self.syncedLyricsService.selectedLyricsVariantID {
                            Label(Self.variantTitle(variant), systemImage: "checkmark")
                        } else {
                            Text(Self.variantTitle(variant))
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "square.stack.3d.up")
                    Text(String(localized: "\(variants.count) versions"))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(String(localized: "Switch between community lyric versions"))
            .accessibilityLabel(String(localized: "Lyric versions"))
        }
    }

    /// A version's menu row: its fidelity and submitter, then the community's
    /// vote count when the provider reports one.
    private static func variantTitle(_ variant: LyricsVariant) -> String {
        guard let count = variant.voteCount else { return variant.label }
        return "\(variant.label) · \(String(localized: "\(count) votes"))"
    }
}
