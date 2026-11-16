import SwiftUI

/// The artist page's header: the picture, the name, whichever facts the artist has, and its actions.
///
/// Content aware in both directions. Vertically the cluster hugs what the artist supplied and centres
/// against the picture: a niche artist with no description and no monthly listeners is a name and a row
/// of buttons, not a name stranded above the picture's far edge. Horizontally the header measures the
/// width it is given — a narrow page shrinks the picture and the name and drops a description line — and
/// the actions fall to a second row when their words no longer fit one.
@available(macOS 26.0, *)
struct ArtistHeaderView: View {
    let name: String
    let monthlyListeners: String?
    let description: String?
    let subscriberCount: String?
    let avatarURL: URL?
    let thumbnailURL: URL?
    let logoImage: NSImage?
    let logoIsMonochrome: Bool
    let isSubscribed: Bool
    let canSubscribe: Bool
    let isSubscribing: Bool
    let canShuffle: Bool
    let hasMix: Bool
    let onShuffle: () -> Void
    let onMix: () -> Void
    let onSubscribe: () -> Void

    /// The width the header was drawn into, which is what decides the picture's size and how much room
    /// the words get. Measured off the layout rather than read from the window: the page is a pane.
    @State private var width: CGFloat = 960

    /// Below this the header tightens: a smaller name and one description line fewer.
    private static let compactWidth: CGFloat = 820

    /// The portrait keeps one size at every width. It was tied to the width for a while, and since the
    /// page's own floor (765 pt) is below the compact threshold, a well-known artist's portrait drew at
    /// 120 pt on a perfectly ordinary window — a thumbnail where the page's subject should be.
    private static let artworkSize: CGFloat = 180

    private var isCompact: Bool {
        self.width < Self.compactWidth
    }

    /// Whether the artist gave us anything below the name, which decides how much air the actions get.
    private var hasLines: Bool {
        self.monthlyListeners != nil || !(self.description ?? "").isEmpty
    }

    var body: some View {
        HStack(alignment: .center, spacing: self.isCompact ? 16 : 24) {
            self.artwork

            VStack(alignment: .leading, spacing: 8) {
                self.nameSlot
                    .animation(.easeInOut(duration: 0.35), value: self.logoImage == nil)

                if let monthlyListeners = self.monthlyListeners {
                    Text("\(monthlyListeners) monthly listeners")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let description = self.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(self.isCompact ? 2 : 3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                self.actions
                    .padding(.top, self.hasLines ? 6 : 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            guard abs(newWidth - self.width) > 0.5 else { return }
            self.width = newWidth
        }
    }

    // MARK: - Artwork

    private var artwork: some View {
        CachedAsyncImage(url: self.avatarURL, fallbackURL: self.thumbnailURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: Self.artworkSize * 0.22))
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: Self.artworkSize, height: Self.artworkSize)
        .clipShape(.circle)
    }

    // MARK: - Name

    /// The artist's own wordmark when Apple Music has one, the name otherwise.
    ///
    /// One slot, not two stacked in a `ZStack`: a name sharing a `ZStack` with the wordmark is laid out at
    /// its single-line ideal width, so a long name ran past the header instead of wrapping. The slot takes
    /// the height of whichever it shows, so a niche artist's name is not sitting in an empty box reserved
    /// for a wordmark that will never arrive.
    @ViewBuilder
    private var nameSlot: some View {
        if let logoImage = self.logoImage {
            Image(nsImage: logoImage)
                .resizable()
                .renderingMode(self.logoIsMonochrome ? .template : .original)
                .interpolation(.high)
                .foregroundStyle(.primary)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: self.isCompact ? 220 : 320, maxHeight: 60, alignment: .leading)
                .accessibilityLabel(self.name)
                .transition(.opacity)
        } else {
            // No `fixedSize(vertical:)` here: it resolves the text's ideal height at an unbounded width,
            // which is one line, and a long name is then truncated instead of wrapped.
            Text(self.name)
                .font(.system(size: self.isCompact ? 24 : 30, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .transition(.opacity)
        }
    }

    // MARK: - Actions

    /// One row while the words fit, two when they do not: the header is also the page's narrowest
    /// surface when the sidebar and the inspector are both open.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                self.shuffleButton
                if self.hasMix {
                    self.mixButton
                }
                if self.canSubscribe {
                    self.subscribeButton
                }
                self.subscriberNote
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    self.shuffleButton
                    if self.hasMix {
                        self.mixButton
                    }
                }
                HStack(spacing: 10) {
                    if self.canSubscribe {
                        self.subscribeButton
                    }
                    self.subscriberNote
                }
            }

            self.shuffleButton
        }
    }

    private var shuffleButton: some View {
        Button(action: self.onShuffle) {
            Label("Shuffle", systemImage: "shuffle")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!self.canShuffle)
    }

    private var mixButton: some View {
        Button(action: self.onMix) {
            Label("Mix", systemImage: "play.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var subscribeButton: some View {
        let button = Button(action: self.onSubscribe) {
            if self.isSubscribing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Text(self.isSubscribed ? String(localized: "Subscribed") : String(localized: "Subscribe"))
            }
        }
        .controlSize(.large)
        .disabled(self.isSubscribing)

        return Group {
            if self.isSubscribed {
                button.buttonStyle(.bordered)
            } else {
                button.buttonStyle(.borderedProminent)
            }
        }
    }

    /// The one place the subscriber count is stated; the button names only its action.
    @ViewBuilder
    private var subscriberNote: some View {
        if let subscriberCount = self.subscriberCount {
            Text("\(subscriberCount) subscribers")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
