import SwiftUI

// MARK: - LyricsSubmitterCredit

/// Credits the community member who submitted the lyrics, with an optional link
/// to their provider profile, and — for a provider whose community votes on
/// lyrics — the controls that vote on this record.
///
/// Rendered at the end of the lyric sheet rather than pinned under it, so it
/// stays out of the reading area until the reader reaches the bottom. The link
/// uses ordinary text colours — never the system accent — so it reads as a
/// caption rather than a call to action. The vote sits beside the name because
/// the credit is where the record is already identified: a vote names the lyrics,
/// not the submitter.
@available(macOS 26.0, *)
struct LyricsSubmitterCredit: View {
    let attribution: LyricsAttribution
    /// Text and glyph colour. The fullscreen player passes white.
    var color: Color = .secondary

    @Environment(\.openURL) private var openURL
    @Environment(SyncedLyricsService.self) private var syncedLyricsService

    var body: some View {
        if self.hasCredit {
            HStack(spacing: 7) {
                if let name = self.attribution.submitterName, !name.isEmpty {
                    self.avatar
                    self.label(name: name)
                }

                self.voteButtons
                Spacer(minLength: 0)
            }
        }
    }

    /// A credit is worth a row when there is somebody to name or something to
    /// vote on.
    private var hasCredit: Bool {
        self.attribution.submitterName?.isEmpty == false || self.syncedLyricsService.currentVote != nil
    }

    // MARK: - Votes

    @ViewBuilder
    private var voteButtons: some View {
        if let vote = self.syncedLyricsService.currentVote {
            HStack(spacing: 1) {
                self.voteButton(.up, vote: vote)

                if let count = vote.count {
                    Text(count.formatted())
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(self.color.opacity(0.8))
                        .accessibilityIdentifier(AccessibilityID.NowPlayingSidebar.lyricsVoteCount)
                        .accessibilityLabel(String(localized: "\(count) votes"))
                }

                self.voteButton(.down, vote: vote)

                if let message = self.syncedLyricsService.voteErrorMessage {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help(message)
                        .accessibilityLabel(message)
                }
            }
            .padding(.leading, 2)
            .opacity(self.syncedLyricsService.isVoting ? 0.5 : 1)
        }
    }

    /// One direction of the vote. The filled glyph is the listener's own vote, so
    /// the row says both what the community thinks and what this listener said.
    private func voteButton(_ direction: LyricsVoteDirection, vote: LyricsVoteState) -> some View {
        let isSelected = vote.direction == direction
        let label = direction == .up
            ? String(localized: "Upvote these lyrics")
            : String(localized: "Downvote these lyrics")
        let symbol: String = switch (direction, isSelected) {
        case (.up, true): "hand.thumbsup.fill"
        case (.up, false): "hand.thumbsup"
        case (.down, true): "hand.thumbsdown.fill"
        case (.down, false): "hand.thumbsdown"
        }

        return Button {
            Task { await self.syncedLyricsService.toggleVote(direction) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(self.color.opacity(isSelected ? 1 : 0.6))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(self.syncedLyricsService.isVoting)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(direction == .up
            ? AccessibilityID.NowPlayingSidebar.lyricsVoteUp
            : AccessibilityID.NowPlayingSidebar.lyricsVoteDown)
    }

    // MARK: - Avatar

    @ViewBuilder
    private var avatar: some View {
        if let url = self.attribution.submitterAvatarURL {
            CachedAsyncImage(
                url: url,
                identity: self.attribution.submitterProfileURL?.absoluteString,
                targetSize: CGSize(width: 36, height: 36)
            ) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                self.monogram
            }
            .frame(width: 16, height: 16)
            .clipShape(.circle)
        } else {
            self.monogram
                .frame(width: 16, height: 16)
                .clipShape(.circle)
        }
    }

    /// Unison generates an avatar for every curator, but a submitter without an
    /// uploaded one comes back with no URL: fall back to their initial.
    private var monogram: some View {
        ZStack {
            Circle().fill(.quaternary)
            Text(self.initial)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(self.color)
        }
    }

    private var initial: String {
        guard let first = self.attribution.submitterName?.first else { return "?" }
        return String(first).uppercased()
    }

    // MARK: - Label

    @ViewBuilder
    private func label(name: String) -> some View {
        if let url = self.attribution.submitterProfileURL {
            Button {
                self.openURL(url)
            } label: {
                HStack(spacing: 3) {
                    Text(String(localized: "Lyrics by \(name)"))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(self.color)
            .help(String(localized: "Open the submitter's profile"))
            .accessibilityLabel(String(localized: "Lyrics by \(name), opens profile"))
        } else {
            Text(String(localized: "Lyrics by \(name)"))
                .font(.caption)
                .foregroundStyle(self.color)
        }
    }
}
