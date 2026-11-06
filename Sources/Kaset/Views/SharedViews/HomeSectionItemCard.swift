import SwiftUI

// MARK: - HomeSectionItemCard

/// Reusable card view for home section items (songs, playlists, albums, artists).
///
/// `Equatable` (with `==` comparing only what the card draws) so the page can apply `.equatable()`:
/// Home's four background continuations each append sections, and every append re-rendered the whole
/// page — re-evaluating every realized card's body to produce the same card. This is ADR-0014's rule
/// for list rows, applied to Home's shelves.
@available(macOS 26.0, *)
struct HomeSectionItemCard: View, Equatable {
    let item: HomeSectionItem
    let rank: Int?
    let action: () -> Void

    /// Card dimensions.
    private static let cardWidth: CGFloat = 160
    private static let cardHeight: CGFloat = 160

    /// Size the artwork is decoded at. `ImageCache` doubles it for Retina, so this asks for a 320 px
    /// bitmap for a 160 pt slot; the default target would have decoded 640 px for every card, which is
    /// the sort of per-card cost ADR-0014 removed from the playlist rows.
    private static let artworkSize = CGSize(width: cardWidth, height: cardHeight)

    /// Hover state for play overlay.
    @State private var isHovering = false

    init(item: HomeSectionItem, rank: Int? = nil, action: @escaping () -> Void) {
        self.item = item
        self.rank = rank
        self.action = action
    }

    /// Compares what the card draws. The action closure is a new value on every page render but never
    /// changes the card, so comparing it would defeat the point of the conformance.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.rank == rhs.rank
    }

    /// Fill for the play overlay shown on hover.
    private var playOverlayStyle: Material {
        .ultraThinMaterial
    }

    var body: some View {
        Button(action: self.action) {
            if let rank {
                self.chartContent(rank: rank)
            } else {
                self.regularContent
            }
        }
        .buttonStyle(.interactiveCard)
        .onHover { hovering in
            withAnimation(AppAnimation.quick) {
                self.isHovering = hovering
            }
        }
    }

    // MARK: - Regular Card Content

    private var regularContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.thumbnail
            self.titleAndSubtitle
        }
    }

    // MARK: - Chart Card Content

    private func chartContent(rank: Int) -> some View {
        ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 8) {
                self.thumbnail
                self.titleAndSubtitle
            }

            // Rank badge overlay with adaptive styling
            Text("\(rank)")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .shadow(color: Color(nsColor: .windowBackgroundColor).opacity(0.8), radius: 4, x: 0, y: 1)
                .padding(.leading, 8)
                .padding(.bottom, 60)
        }
    }

    // MARK: - Shared Components

    private var thumbnail: some View {
        ZStack {
            if let url = self.item.thumbnailURL?.highQualityThumbnailURL {
                CachedAsyncImage(url: url, targetSize: Self.artworkSize) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    self.placeholderView
                }
            } else {
                self.placeholderView
            }
        }
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            // Play overlay on hover (for songs)
            if case .song = self.item, self.isHovering {
                Circle()
                    .fill(self.playOverlayStyle)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundStyle(.primary)
                            .offset(x: 2)
                    }
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    /// Placeholder view for items without thumbnails.
    /// Uses the API-provided color for mood/genre cards, or a gradient based on the title.
    private var placeholderView: some View {
        let gradient = self.gradientForItem
        return Rectangle()
            .fill(gradient)
            .overlay {
                // Show a contextual icon based on item type
                Image(systemName: self.placeholderIcon)
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.8))
            }
    }

    /// Returns appropriate icon for the placeholder based on item type.
    private var placeholderIcon: String {
        switch self.item {
        case .song: "music.note"
        case .album: "square.stack"
        case .playlist: "music.note.list"
        case .artist: "person.fill"
        }
    }

    /// Generates a gradient for the card.
    /// Uses API-provided color (from description) for mood cards, or title-based hash.
    private var gradientForItem: LinearGradient {
        // Check if this is a mood card with color in description
        if case let .playlist(playlist) = item,
           let colorHex = playlist.description,
           colorHex.hasPrefix("#"),
           let color = Color(hex: colorHex)
        {
            // Create a gradient from the API color
            return LinearGradient(
                colors: [color, color.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        // Fallback to title-based gradient
        return Self.gradientForTitle(self.item.title)
    }

    /// Generates a consistent gradient color based on the title string.
    ///
    /// FNV-1a rather than `title.hashValue`: Swift seeds its hasher per process, so a placeholder
    /// gradient silently changed colour on every launch.
    private static func gradientForTitle(_ title: String) -> LinearGradient {
        var seed: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in title.utf8 {
            seed ^= UInt64(byte)
            seed = seed &* 0x0000_0100_0000_01B3
        }
        let hue1 = Double(seed % 360) / 360.0
        let hue2 = (hue1 + 0.1).truncatingRemainder(dividingBy: 1.0)

        let color1 = Color(hue: hue1, saturation: 0.6, brightness: 0.5)
        let color2 = Color(hue: hue2, saturation: 0.7, brightness: 0.35)

        return LinearGradient(
            colors: [color1, color2],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var titleAndSubtitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.item.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: Self.cardWidth, alignment: .leading)

            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: Self.cardWidth, alignment: .leading)
            }
        }
    }
}

#Preview {
    let song = Song(
        id: "test",
        title: "Test Song with a Very Long Title That Should Wrap",
        artists: [Artist(id: "artist1", name: "Test Artist")],
        videoId: "testVideo"
    )
    HStack {
        HomeSectionItemCard(item: .song(song)) {
            // No-op for preview
        }
        HomeSectionItemCard(item: .song(song), rank: 1) {
            // No-op for preview
        }
    }
    .padding()
}
