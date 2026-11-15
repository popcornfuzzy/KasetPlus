import AppKit
import SwiftUI

// MARK: - PodcastFeedCollectionView

/// The podcasts page's shelves, as one AppKit collection view — the shape Home's feed uses (ADR-0046).
///
/// The page used to be a vertical `ScrollView` over a `LazyVStack` of shelves, where every shelf was its
/// own horizontal `ScrollView` carrying a mask, and every card a live SwiftUI view. That is a dozen
/// nested `NSScrollView`s inside a scrolling page, an offscreen pass per shelf for the fade, and a
/// `LazyHStack` that sized a row from the first card it realised — the reason a card with a wrapped
/// title was clipped, and a shorter card sat off its neighbours' line.
///
/// One collection view with orthogonal shelf sections removes all three: the page has one scroll view,
/// a shelf's horizontal scrolling is AppKit's, cells are recycled, and each card is laid out in a fixed
/// slot so every card in a row starts on the same line by construction.
@available(macOS 26.0, *)
struct PodcastFeedCollectionView: NSViewControllerRepresentable {
    let sections: [PodcastSection]
    let onSelectShow: (PodcastShow) -> Void
    let onPlayEpisode: (PodcastEpisode) -> Void

    func makeNSViewController(context: Context) -> PodcastFeedCollectionViewController {
        PodcastFeedCollectionViewController()
    }

    func updateNSViewController(_ controller: PodcastFeedCollectionViewController, context: Context) {
        controller.update(
            sections: self.sections,
            onSelectShow: self.onSelectShow,
            onPlayEpisode: self.onPlayEpisode
        )
    }
}

// MARK: - Identifiers

/// A shelf is two sections in the layout: its title, then its row of cards.
///
/// The title is its own section rather than a boundary supplementary item — a supplementary item belongs
/// to the shelf's orothogonal container and would scroll away sideways with the cards.
enum PodcastFeedSection: Hashable {
    case header(String)
    case items(String)
}

/// What a collection-view item draws.
enum PodcastFeedItem: Hashable {
    case title(id: String, text: String)
    case show(id: String, show: PodcastShow)
    case episode(id: String, episode: PodcastEpisode)
}

// MARK: - PodcastFeedSnapshot

/// Builds the diffable snapshot the podcasts collection view applies.
///
/// Pure, so the identifier rules are testable without a window: an identifier carries the shelf id and
/// the card's position, because a show or episode can appear in more than one shelf and duplicate item
/// identifiers are a diffable-snapshot crash.
enum PodcastFeedSnapshot {
    static func make(sections: [PodcastSection]) -> NSDiffableDataSourceSnapshot<PodcastFeedSection, PodcastFeedItem> {
        var snapshot = NSDiffableDataSourceSnapshot<PodcastFeedSection, PodcastFeedItem>()

        for section in sections {
            let header = PodcastFeedSection.header(section.id)
            let shelf = PodcastFeedSection.items(section.id)
            snapshot.appendSections([header, shelf])

            snapshot.appendItems(
                [.title(id: "\(section.id)#title", text: section.title)],
                toSection: header
            )

            let cards = section.items.enumerated().map { index, item -> PodcastFeedItem in
                switch item {
                case let .show(show):
                    return .show(id: "\(section.id)#\(index)#\(show.id)", show: show)
                case let .episode(episode):
                    return .episode(id: "\(section.id)#\(index)#\(episode.id)", episode: episode)
                }
            }
            snapshot.appendItems(cards, toSection: shelf)
        }

        return snapshot
    }
}

// MARK: - PodcastFeedMetrics

/// The size of a card's slot.
///
/// A card's slot is its card plus the bleed the hover scale and shadow draw into: a hosting view clips
/// at its own bounds, so a slot the size of the card crops both. A card's title is a single truncated
/// line, so a card of each kind is exactly one height; these are those heights, measured
/// (`PodcastFeedTests` measures the real cards against them), and a card that grows cannot silently clip
/// in a slot that did not.
enum PodcastFeedMetrics {
    static let bleed: CGFloat = 10

    static let showCardWidth: CGFloat = 160
    static let showCardHeight: CGFloat = 203
    static let episodeCardWidth: CGFloat = 200
    static let episodeCardHeight: CGFloat = 155

    static var showSlotWidth: CGFloat { self.showCardWidth + (2 * self.bleed) }
    static var showSlotHeight: CGFloat { self.showCardHeight + (2 * self.bleed) }
    static var episodeSlotWidth: CGFloat { self.episodeCardWidth + (2 * self.bleed) }
    static var episodeSlotHeight: CGFloat { self.episodeCardHeight + (2 * self.bleed) }

    static func slotWidth(for item: PodcastSectionItem) -> CGFloat {
        switch item {
        case .show: self.showSlotWidth
        case .episode: self.episodeSlotWidth
        }
    }

    static func slotHeight(for item: PodcastSectionItem) -> CGFloat {
        switch item {
        case .show: self.showSlotHeight
        case .episode: self.episodeSlotHeight
        }
    }
}

// MARK: - PodcastFeedCollectionViewController

@available(macOS 26.0, *)
@MainActor
final class PodcastFeedCollectionViewController: NSViewController {
    private let collectionView = ShelfFeedCollectionView()
    private var dataSource: NSCollectionViewDiffableDataSource<PodcastFeedSection, PodcastFeedItem>?
    /// The sections the layout must answer for, in order. The layout provider is handed an index, not an
    /// identifier, so the order the snapshot applied is kept here.
    private var sectionKinds: [PodcastFeedSection] = []
    private var sections: [PodcastSection] = []
    private var onSelectShow: ((PodcastShow) -> Void)?
    private var onPlayEpisode: ((PodcastEpisode) -> Void)?
    private var hasAppliedSnapshot = false

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PodcastFeedCollectionViewController is not loaded from a nib")
    }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        self.collectionView.autoresizingMask = [.width]
        self.collectionView.backgroundColors = [.clear]
        self.collectionView.isSelectable = false
        self.collectionView.collectionViewLayout = self.makeLayout()
        self.collectionView.register(
            HomeFeedHeaderItem.self,
            forItemWithIdentifier: HomeFeedHeaderItem.reuseIdentifier
        )
        self.collectionView.register(
            PodcastShowItem.self,
            forItemWithIdentifier: PodcastShowItem.reuseIdentifier
        )
        self.collectionView.register(
            PodcastEpisodeItem.self,
            forItemWithIdentifier: PodcastEpisodeItem.reuseIdentifier
        )

        scrollView.documentView = self.collectionView
        self.view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.makeDataSource()
    }

    /// Applies `sections`. Called on every page render, so it does nothing unless the feed changed.
    func update(
        sections: [PodcastSection],
        onSelectShow: @escaping (PodcastShow) -> Void,
        onPlayEpisode: @escaping (PodcastEpisode) -> Void
    ) {
        // The first update can arrive before the view is loaded; the snapshot needs the data source,
        // which `viewDidLoad` builds.
        self.loadViewIfNeeded()

        self.onSelectShow = onSelectShow
        self.onPlayEpisode = onPlayEpisode
        guard sections != self.sections else { return }
        self.sections = sections

        let snapshot = PodcastFeedSnapshot.make(sections: sections)
        self.sectionKinds = snapshot.sectionIdentifiers
        self.collectionView.declaredContentHeight = Self.contentHeight(for: sections)
        self.dataSource?.apply(snapshot, animatingDifferences: self.hasAppliedSnapshot)
        self.hasAppliedSnapshot = true
        self.collectionView.collectionViewLayout?.invalidateLayout()
        self.collectionView.fitDocumentToLayout()
        self.collectionView.needsLayout = true

        DiagnosticsLogger.ui.debug(
            "Podcasts feed: \(sections.count) sections, declared content height \(Self.contentHeight(for: sections), privacy: .public), measured \(self.collectionView.collectionViewLayout?.collectionViewContentSize.height ?? 0, privacy: .public)"
        )
    }

    /// What the sections need vertically: a title row (30 pt + 16 above + 10 below) and the tallest
    /// card slot of its shelf, per shelf. Mirrors the layout constants in `section(at:)`.
    static func contentHeight(for sections: [PodcastSection]) -> CGFloat {
        sections.reduce(0) { height, section in
            height + 56 + (section.items.map(PodcastFeedMetrics.slotHeight(for:)).max() ?? 0)
        }
    }

    private func makeDataSource() {
        self.dataSource = NSCollectionViewDiffableDataSource<PodcastFeedSection, PodcastFeedItem>(
            collectionView: self.collectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let self else { return nil }

            switch item {
            case let .title(_, text):
                guard let header = collectionView.makeItem(
                    withIdentifier: HomeFeedHeaderItem.reuseIdentifier,
                    for: indexPath
                ) as? HomeFeedHeaderItem else { return nil }
                header.configure(text: text)
                return header

            case let .show(_, show):
                guard let cell = collectionView.makeItem(
                    withIdentifier: PodcastShowItem.reuseIdentifier,
                    for: indexPath
                ) as? PodcastShowItem else { return nil }
                cell.configure(show: show) { [weak self] selected in
                    self?.onSelectShow?(selected)
                }
                return cell

            case let .episode(_, episode):
                guard let cell = collectionView.makeItem(
                    withIdentifier: PodcastEpisodeItem.reuseIdentifier,
                    for: indexPath
                ) as? PodcastEpisodeItem else { return nil }
                cell.configure(episode: episode) { [weak self] selected in
                    self?.onPlayEpisode?(selected)
                }
                return cell
            }
        }
    }

    // MARK: - Layout

    private func makeLayout() -> NSCollectionViewCompositionalLayout {
        let configuration = NSCollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = .vertical
        // Zero: each title's own insets are the only space between shelves.
        configuration.interSectionSpacing = 0

        return NSCollectionViewCompositionalLayout(sectionProvider: { [weak self] index, _ in
            guard let self else { return Self.emptyShelfSection() }
            return self.section(at: index)
        }, configuration: configuration)
    }

    private func section(at index: Int) -> NSCollectionLayoutSection {
        guard index < self.sectionKinds.count else { return Self.emptyShelfSection() }

        switch self.sectionKinds[index] {
        case .header:
            let size = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .absolute(30)
            )
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            // The page's own top padding lives on the first title, since the collection view insets
            // its sections rather than its content.
            section.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 10, trailing: 24)
            return section

        case let .items(id):
            guard let shelf = self.sections.first(where: { $0.id == id }), !shelf.items.isEmpty else {
                return Self.emptyShelfSection()
            }
            return Self.shelfSection(items: shelf.items)
        }
    }

    /// A shelf: its cards laid out continuously along the horizontal axis.
    ///
    /// The group is sized to exactly the slots it holds, so it never leaves the width of a partial group
    /// as a bare gap mid-shelf. Episode cards are wider than show cards and the two can share a shelf, so
    /// the frames are placed by hand: one group height for the shelf (its tallest card), every card
    /// starting at its top.
    private static func shelfSection(items: [PodcastSectionItem]) -> NSCollectionLayoutSection {
        let widths = items.map(PodcastFeedMetrics.slotWidth(for:))
        let height = items.map(PodcastFeedMetrics.slotHeight(for:)).max() ?? 0

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .absolute(widths.reduce(0, +)),
            heightDimension: .absolute(height)
        )
        let group = NSCollectionLayoutGroup.custom(layoutSize: groupSize) { _ in
            var leading: CGFloat = 0
            return widths.map { width in
                defer { leading += width }
                return NSCollectionLayoutGroupCustomItem(
                    frame: CGRect(x: leading, y: 0, width: width, height: height)
                )
            }
        }

        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24)
        return section
    }

    /// A section with nothing in it: a shelf whose cards all went away still needs a layout answer.
    private static func emptyShelfSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(
            widthDimension: .absolute(1),
            heightDimension: .absolute(1)
        )
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
        return NSCollectionLayoutSection(group: group)
    }
}

// MARK: - PodcastShowItem

/// A recycled cell hosting one show card.
@available(macOS 26.0, *)
@MainActor
final class PodcastShowItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("PodcastShowItem")

    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    override func loadView() {
        self.view = self.hostingView
    }

    func configure(show: PodcastShow, onSelect: @escaping (PodcastShow) -> Void) {
        self.hostingView.rootView = AnyView(PodcastShowCellContent(show: show, onSelect: onSelect))
    }
}

@available(macOS 26.0, *)
private struct PodcastShowCellContent: View {
    let show: PodcastShow
    let onSelect: (PodcastShow) -> Void

    var body: some View {
        PodcastShowCard(show: self.show) {
            self.onSelect(self.show)
        }
        .padding(PodcastFeedMetrics.bleed)
        .frame(
            width: PodcastFeedMetrics.showSlotWidth,
            height: PodcastFeedMetrics.showSlotHeight,
            alignment: .topLeading
        )
    }
}

// MARK: - PodcastEpisodeItem

/// A recycled cell hosting one episode card.
@available(macOS 26.0, *)
@MainActor
final class PodcastEpisodeItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("PodcastEpisodeItem")

    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    override func loadView() {
        self.view = self.hostingView
    }

    func configure(episode: PodcastEpisode, onPlay: @escaping (PodcastEpisode) -> Void) {
        self.hostingView.rootView = AnyView(PodcastEpisodeCellContent(episode: episode, onPlay: onPlay))
    }
}

@available(macOS 26.0, *)
private struct PodcastEpisodeCellContent: View {
    let episode: PodcastEpisode
    let onPlay: (PodcastEpisode) -> Void

    var body: some View {
        PodcastEpisodeCard(episode: self.episode) {
            self.onPlay(self.episode)
        }
        .padding(PodcastFeedMetrics.bleed)
        .frame(
            width: PodcastFeedMetrics.episodeSlotWidth,
            height: PodcastFeedMetrics.episodeSlotHeight,
            alignment: .topLeading
        )
    }
}
