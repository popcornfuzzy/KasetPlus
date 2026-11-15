import AppKit
import SwiftUI
import Testing

@testable import Kaset

/// Coverage for the podcasts page's collection view: the snapshot it applies, and the cards fitting the
/// slots its layout gives them.
@Suite(.serialized, .tags(.viewModel))
@MainActor
struct PodcastFeedTests {
    private static func episode(id: String, title: String) -> PodcastEpisode {
        PodcastEpisode(
            id: id,
            title: title,
            showTitle: "The Show",
            showBrowseId: nil,
            description: nil,
            thumbnailURL: nil,
            publishedDate: "1d ago",
            duration: "36 min",
            durationSeconds: nil,
            playbackProgress: 0.2,
            isPlayed: false
        )
    }

    private static func section() -> PodcastSection {
        PodcastSection(
            id: "keep-listening",
            title: "Keep listening",
            items: [
                .episode(self.episode(id: "ep-1", title: "A title long enough to wrap onto a second line")),
                .episode(self.episode(id: "ep-2", title: "Short")),
            ]
        )
    }

    @Test("A shelf becomes a title section and a row section")
    func shelfBecomesTwoSections() {
        let section = Self.section()
        let snapshot = PodcastFeedSnapshot.make(sections: [section])

        #expect(snapshot.numberOfSections == 2)
        #expect(snapshot.itemIdentifiers(inSection: .header(section.id)).count == 1)
        #expect(snapshot.itemIdentifiers(inSection: .items(section.id)).count == section.items.count)
    }

    @Test("The same episode in two shelves keeps unique identifiers")
    func repeatedItemsStayUnique() {
        let first = Self.section()
        let second = PodcastSection(id: "up next", title: "Up next", items: first.items)
        let snapshot = PodcastFeedSnapshot.make(sections: [first, second])

        let identifiers = snapshot.itemIdentifiers
        #expect(Set(identifiers).count == identifiers.count)
        #expect(identifiers.count == 2 + first.items.count + second.items.count)
    }

    @Test("A shelf's height is its title plus its tallest card")
    func shelfHeightAddsTitleAndTallestSlot() {
        let show = PodcastShow(
            id: "show",
            title: "A show",
            author: nil,
            description: nil,
            thumbnailURL: nil,
            episodeCount: nil
        )
        let mixed = PodcastSection(
            id: "mixed",
            title: "Mixed",
            items: [.episode(Self.episode(id: "ep-1", title: "Episode")), .show(show)]
        )

        let expected = 56 + max(PodcastFeedMetrics.episodeSlotHeight, PodcastFeedMetrics.showSlotHeight)
        #expect(PodcastFeedCollectionViewController.contentHeight(for: [mixed]) == expected)
    }

    /// A card is a fixed frame — artwork, a title capped at two lines, the last row anchored to the
    /// bottom — so how far a title wraps cannot move anything in it. Fitted to its text instead, a card
    /// with a one-line title was 17 pt shorter than its neighbours, with its last row that much higher:
    /// the shelf read as cards at different heights. Measured here, so a card that starts sizing itself
    /// to its title again fails this.
    @Test("Title length cannot change a card's geometry")
    func titleLengthCannotChangeCardGeometry() throws {
        let oneLine = Self.episode(id: "ep-1", title: "Short")
        let twoLines = Self.episode(
            id: "ep-2",
            title: "Why China's AI Bubble Popped and Ours Haven't, Explained in Full Detail"
        )
        let oneLineHeight = try Self.fittingHeight(
            of: PodcastEpisodeCard(episode: oneLine) {},
            width: PodcastFeedMetrics.episodeCardWidth
        )
        let twoLinesHeight = try Self.fittingHeight(
            of: PodcastEpisodeCard(episode: twoLines) {},
            width: PodcastFeedMetrics.episodeCardWidth
        )
        #expect(
            oneLineHeight == PodcastFeedMetrics.episodeCardHeight,
            "a one-line title gives a \(oneLineHeight) pt episode card, not \(PodcastFeedMetrics.episodeCardHeight)"
        )
        #expect(twoLinesHeight == oneLineHeight, "an episode card changes height with its title")

        let quietShow = PodcastShow(
            id: "show-1",
            title: "Short",
            author: nil,
            description: nil,
            thumbnailURL: nil,
            episodeCount: nil
        )
        let verboseShow = PodcastShow(
            id: "show-2",
            title: "A show title long enough to wrap onto a second line, twice",
            author: "Somebody",
            description: nil,
            thumbnailURL: nil,
            episodeCount: nil
        )
        let quietHeight = try Self.fittingHeight(
            of: PodcastShowCard(show: quietShow) {},
            width: PodcastFeedMetrics.showCardWidth
        )
        let verboseHeight = try Self.fittingHeight(
            of: PodcastShowCard(show: verboseShow) {},
            width: PodcastFeedMetrics.showCardWidth
        )
        #expect(
            quietHeight == PodcastFeedMetrics.showCardHeight,
            "a show with no author gives a \(quietHeight) pt card, not \(PodcastFeedMetrics.showCardHeight)"
        )
        #expect(verboseHeight == quietHeight, "a show card changes height with its title or author")
    }

    /// The heights above are only safe while the typography fits inside them: one title line plus the
    /// metadata line. This measures the text at each card's width, so a text style or spacing change that
    /// outgrows a card fails here instead of clipping in the shelf.
    @Test("A podcast card's text fits inside the card")
    func cardTextFitsTheFixedHeight() throws {
        let titleBlock = try Self.fittingHeight(
            of: Text("A title long enough to wrap onto a second line, and then a bit more than that")
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1),
            width: PodcastFeedMetrics.episodeCardWidth
        )
        let metaBlock = try Self.fittingHeight(
            of: Text("The Show • 3d ago").font(.caption).lineLimit(1),
            width: PodcastFeedMetrics.episodeCardWidth
        )

        // The card's stack: artwork, 8 pt, the title block, 8 pt, the metadata row.
        let episodeNeeded = 112 + 8 + titleBlock + 8 + metaBlock
        #expect(
            episodeNeeded <= PodcastFeedMetrics.episodeCardHeight,
            "an episode card needs \(episodeNeeded) pt of content but is \(PodcastFeedMetrics.episodeCardHeight) pt"
        )

        let showNeeded = 160 + 8 + titleBlock + 8 + metaBlock
        #expect(
            showNeeded <= PodcastFeedMetrics.showCardHeight,
            "a show card needs \(showNeeded) pt of content but is \(PodcastFeedMetrics.showCardHeight) pt"
        )
    }

    private static func fittingHeight(of card: some View, width: CGFloat) throws -> CGFloat {
        let hosting = NSHostingView(rootView: card.frame(width: width, alignment: .topLeading))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        try #require(height > 0, "the card never laid out")
        return ceil(height)
    }
}
