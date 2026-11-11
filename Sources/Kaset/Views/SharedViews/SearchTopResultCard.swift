import SwiftUI

// MARK: - SearchTopResultCard

/// YouTube Music's "Top result" as the app's own quiet tile: a head with kind, title, supporting line
/// and actions, and the rows listed beside it beneath a hairline, three across so a wide window has no
/// dead middle. Flat on purpose — a fill and a hairline rather than glass.
@available(macOS 26.0, *)
struct SearchTopResultCard: View {
    let topResult: SearchTopResult
    let onSelect: (SearchResultItem) -> Void
    let onQuickAction: (SearchResultItem, QuickAction) -> Void

    private static let artworkSize: CGFloat = 64
    private static let cornerRadius: CGFloat = 16

    /// The artwork's corners at the card's scale, and the rows' at theirs: a 64 pt tile cannot take the
    /// card's own 16 pt without reading as a pill.
    private static let artworkCornerRadius: CGFloat = 10

    /// A row's hover highlight and the inset its content keeps from that highlight.
    private static let rowCornerRadius: CGFloat = 12
    private static let rowInset: CGFloat = 6

    /// The thumbnail's corners are the row's minus the inset, so the two curves stay concentric: equal
    /// radii on nested corners bow away from each other by exactly the padding.
    private static let rowArtworkCornerRadius: CGFloat = rowCornerRadius - rowInset

    /// The actions the card offers without opening the item. An artist's two both need the artist page
    /// for their tracks; a podcast show has nothing to play, so it keeps only the chevron.
    enum QuickAction: Hashable {
        case play
        case shuffle
        case mix

        var symbol: String {
            switch self {
            case .play: "play.fill"
            case .shuffle: "shuffle"
            case .mix: "play.circle"
            }
        }

        var title: String {
            switch self {
            case .play: String(localized: "Play")
            case .shuffle: String(localized: "Shuffle")
            case .mix: String(localized: "Mix")
            }
        }
    }

    var body: some View {
        Button {
            self.onSelect(self.topResult.item)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                self.head

                if !self.topResult.relatedItems.isEmpty {
                    Rectangle()
                        .fill(.primary.opacity(0.06))
                        .frame(height: 1)

                    self.relatedStrip
                }
            }
            .padding(14)
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: Self.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: Self.cornerRadius))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Head

    /// The artwork lines up with the kind line rather than the row's middle: a two-line title makes the
    /// text taller than the artwork, and centring then floats the tile down beside the text instead of
    /// starting it with the title.
    private var head: some View {
        HStack(alignment: .top, spacing: 16) {
            self.artwork

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: self.topResult.item.resultType)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(alignment: .center, spacing: 6) {
                    Text(verbatim: self.topResult.item.title)
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    // With the actions holding the trailing edge, the chevron rides with its title.
                    if !self.isSong {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }

                if let detail = self.detailLine {
                    Text(verbatim: detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 16)

            // Centred on the head, so a two-line title does not strand the actions above it.
            if !self.quickActions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(self.quickActions, id: \.self) { action in
                        self.quickActionButton(action)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private var isSong: Bool {
        if case .song = self.topResult.item {
            return true
        }
        return false
    }

    private var artwork: some View {
        CachedAsyncImage(
            url: self.topResult.item.thumbnailURL?.highQualityThumbnailURL,
            targetSize: CGSize(width: Self.artworkSize * 2, height: Self.artworkSize * 2)
        ) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: self.topResult.item.systemImage)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: Self.artworkSize, height: Self.artworkSize)
        .clipShape(self.artworkShape)
        .overlay {
            self.artworkShape
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var artworkShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: self.topResult.item.isArtist ? Self.artworkSize / 2 : Self.artworkCornerRadius,
            style: .continuous
        )
    }

    /// The kind is the quiet line above the title, the way a release card puts the year there; this is
    /// what is left of YouTube Music's own subtitle once its leading kind is gone ("32M monthly
    /// audience", "Oasis • 1995").
    private var detailLine: String? {
        if case let .song(song) = self.topResult.item {
            var parts: [String] = []
            if !song.artistsDisplay.isEmpty {
                parts.append(song.artistsDisplay)
            }
            if song.duration != nil {
                parts.append(song.durationDisplay)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " • ")
        }

        guard let subtitle = self.topResult.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subtitle.isEmpty
        else { return nil }

        let kind = self.topResult.item.resultType
        guard subtitle != kind else { return nil }
        guard subtitle.hasPrefix(kind) else { return subtitle }

        let remainder = subtitle.dropFirst(kind.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: " •\u{00A0}"))
        return remainder.isEmpty ? nil : remainder
    }

    private var quickActions: [QuickAction] {
        switch self.topResult.item {
        case .song: [.play]
        case .album, .playlist: [.play, .shuffle]
        case .artist: [.shuffle, .mix]
        case .podcastShow: []
        }
    }

    /// Labeled and sized like the artist page's own buttons, and dressed the same way: the first action
    /// wears the accent that page gives Subscribe, the rest stay quiet.
    private func quickActionButton(_ action: QuickAction) -> some View {
        let title = self.topResult.item.title

        let button = Button {
            self.onQuickAction(self.topResult.item, action)
        } label: {
            Label(action.title, systemImage: action.symbol)
                .labelStyle(.titleAndIcon)
                // The title beside it gives way instead of the word turning into "Shuf…".
                .fixedSize()
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .help("\(action.title) \(title)")
        .accessibilityLabel("\(action.title) \(title)")

        return Group {
            if action == self.quickActions.first {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Related Rows

    private var relatedStrip: some View {
        HStack(alignment: .center, spacing: 10) {
            ForEach(self.topResult.relatedItems.prefix(3)) { item in
                self.relatedRow(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func relatedRow(_ item: SearchResultItem) -> some View {
        Button {
            self.onSelect(item)
        } label: {
            HStack(spacing: 10) {
                CachedAsyncImage(
                    url: item.thumbnailURL?.highQualityThumbnailURL,
                    targetSize: CGSize(width: 72, height: 72)
                ) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 36, height: 36)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: item.isArtist ? 18 : Self.rowArtworkCornerRadius,
                        style: .continuous
                    )
                )

                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    Text(verbatim: self.rowSubtitle(item))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            // The row's hover highlight is its own shape, so the artwork and the text keep the inset
            // that makes their corners concentric with it.
            .padding(Self.rowInset)
            .contentShape(.rect(cornerRadius: Self.rowCornerRadius))
        }
        .buttonStyle(.interactiveRow(cornerRadius: Self.rowCornerRadius, hapticFeedback: .navigation))
    }

    private func rowSubtitle(_ item: SearchResultItem) -> String {
        var parts: [String] = []
        if let subtitle = item.subtitle {
            parts.append(subtitle)
        }
        if case let .song(song) = item, song.duration != nil {
            parts.append(song.durationDisplay)
        }
        if parts.isEmpty {
            parts.append(item.resultType)
        }
        return parts.joined(separator: " • ")
    }
}
