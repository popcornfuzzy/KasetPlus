import AppKit
import SwiftUI

// MARK: - HomeFeedCollectionView

/// Home's feed, as one AppKit collection view.
///
/// Home used to be a vertical `ScrollView` of `LazyVStack` shelves where each shelf was its own
/// horizontal SwiftUI `ScrollView`: a dozen nested `NSScrollView`s inside a page that scrolls
/// vertically, each shelf carrying a mask to soften its trailing edge — an offscreen pass over every
/// card it draws — with a card that re-evaluated whenever the page did. That is not a cost a modifier
/// tunes away; it is what the composition charges on macOS.
///
/// This is the platform's own answer to that shape. One scroll view, one collection view, and a
/// compositional layout whose shelves scroll orthogonally (`.continuous`):
///
/// - cells are recycled by AppKit instead of a live SwiftUI tree being kept per shelf;
/// - a shelf clips its own content, so it no longer needs a mask to end cleanly against the
///   Now Playing column;
/// - the shelf's scrolling is AppKit's, not a nested SwiftUI scroll view's.
///
/// The card itself is unchanged — still `HomeSectionItemCard`, with its hover, play badge, artwork
/// and typography — hosted in a recycled cell. Only the container changed.
@available(macOS 26.0, *)
struct HomeFeedCollectionView: NSViewControllerRepresentable {
    let sections: [HomeSection]
    let client: any YTMusicClientProtocol
    let playerService: PlayerService
    let likeStatusManager: SongLikeStatusManager
    let libraryViewModel: LibraryViewModel?
    let onSelect: (HomeSectionItem) -> Void

    func makeNSViewController(context: Context) -> HomeFeedCollectionViewController {
        HomeFeedCollectionViewController(
            client: self.client,
            playerService: self.playerService,
            likeStatusManager: self.likeStatusManager,
            libraryViewModel: self.libraryViewModel
        )
    }

    func updateNSViewController(_ controller: HomeFeedCollectionViewController, context: Context) {
        controller.update(sections: self.sections, onSelect: self.onSelect)
    }
}

// MARK: - Identifiers

/// A shelf is two sections in the layout: its title, then its row of cards.
///
/// The title is its own section rather than a boundary supplementary item because a supplementary
/// item belongs to the shelf's *orthogonal* container — it would scroll away sideways with the cards.
/// As a section it sits in the page's vertical stack, exactly where a title belongs.
enum HomeFeedSection: Hashable {
    case header(String)
    case items(String)
}

/// What a collection-view item draws.
enum HomeFeedItem: Hashable {
    case title(id: String, text: String)
    case card(id: String, content: HomeSectionItem, rank: Int?)
}

// MARK: - HomeFeedSnapshot

/// Builds the diffable snapshot Home's collection view applies.
///
/// Pure, so the identifier rules are testable without a window: every identifier is unique even when
/// the same song appears in two shelves, which a diffable snapshot requires, and a chart shelf ranks
/// its cards.
enum HomeFeedSnapshot {
    static func make(sections: [HomeSection]) -> NSDiffableDataSourceSnapshot<HomeFeedSection, HomeFeedItem> {
        var snapshot = NSDiffableDataSourceSnapshot<HomeFeedSection, HomeFeedItem>()

        for section in sections {
            let header = HomeFeedSection.header(section.id)
            let shelf = HomeFeedSection.items(section.id)
            snapshot.appendSections([header, shelf])

            snapshot.appendItems(
                [.title(id: "\(section.id)#title", text: section.title)],
                toSection: header
            )

            let cards = section.items.enumerated().map { index, item in
                HomeFeedItem.card(
                    // The position is part of the identifier: one feed can show the same song in two
                    // shelves, and duplicate item identifiers are a diffable-snapshot crash.
                    id: "\(section.id)#\(index)#\(item.id)",
                    content: item,
                    rank: section.isChart ? index + 1 : nil
                )
            }
            snapshot.appendItems(cards, toSection: shelf)
        }

        return snapshot
    }
}

// MARK: - HomeCardEnvironment

/// The services a card's context menu reads, handed to each hosted cell.
///
/// A cell's `NSHostingView` is its own SwiftUI root, so it does not inherit the page's environment.
/// These are the same live instances the page holds — the menu reads them when it opens, as before.
@available(macOS 26.0, *)
@MainActor
struct HomeCardEnvironment {
    let client: any YTMusicClientProtocol
    let playerService: PlayerService
    let likeStatusManager: SongLikeStatusManager
    let libraryViewModel: LibraryViewModel?
}

// MARK: - HomeCollectionView

/// A collection view that keeps the scroll view's document as tall as its layout.
///
/// As a representable's document view the collection view is framed to the *visible* area and AppKit
/// never grows it: the page scrolled one screen and stopped, with the rest of the feed below an edge it
/// could not reach. A collection view's own layout knows its content size, so the height is taken from
/// it here, once per layout pass, with the clip view's height as the floor.
@available(macOS 26.0, *)
final class HomeCollectionView: NSCollectionView {
    /// Fades both page edges where a shelf runs past them.
    ///
    /// Masked onto *this* view, not the scroll view's clip view. A mask smaller than the view it masks
    /// makes everything outside it transparent, and a clip view's mask is sized by hand — sized once,
    /// early, it cut the page off part-way down. This one is always exactly the bounds of the content
    /// it masks.
    ///
    /// The band matches the sections' own 24 pt inset, so at rest the first and last card sit exactly
    /// where each ramp reaches full opacity — a short shelf is never dimmed — while a shelf that
    /// continues past the page dissolves at both of its edges.
    private static let fadeWidth: CGFloat = 24

    /// ADR-0045's ramp: opaque for most of the band, so a card stays readable to its very edge. The
    /// trailing half is this mirrored, built in `updateEdgeFade`.
    private static let fadeRamp: [(position: CGFloat, alpha: CGFloat)] = [
        (0, 0), (0.1, 0.32), (0.28, 0.66), (0.5, 0.88), (0.75, 0.97), (1, 1),
    ]

    /// The width the fade was last laid out for, so the layer is only rebuilt on a resize.
    private var fadedWidth: CGFloat = 0

    /// The height this feed's sections need, computed from the layout constants.
    ///
    /// `collectionViewContentSize` is only correct once the layout has been prepared for the current
    /// width, and the document was being sized before that: the page then scrolled as far as the
    /// height it had been given and stopped. The arithmetic is the floor, so the document is never
    /// shorter than the sections it holds, whatever the layout reports at that moment.
    var declaredContentHeight: CGFloat = 0

    private let edgeFade: CAGradientLayer = {
        let layer = CAGradientLayer()
        layer.startPoint = CGPoint(x: 0, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 0.5)
        return layer
    }()

    override func layout() {
        super.layout()
        self.fitDocumentToLayout()
        self.configureShelfScrollViews()
        self.updateEdgeFade()
    }

    /// Grows the document to the layout's content height (AppKit never does this for a representable's
    /// document view), and keeps the fade spanning the whole document.
    func fitDocumentToLayout() {
        guard let clip = self.enclosingScrollView?.contentView else { return }

        // The width the layout measures against must be the visible width first: the header sections
        // are fractional, so the content size depends on it.
        if abs(self.frame.width - clip.bounds.width) > 0.5 {
            var frame = self.frame
            frame.size.width = clip.bounds.width
            super.setFrameSize(frame.size)
            self.collectionViewLayout?.invalidateLayout()
            return
        }

        let measured = self.collectionViewLayout?.collectionViewContentSize.height ?? 0
        let height = max(measured, self.declaredContentHeight, clip.bounds.height)
        guard abs(self.frame.height - height) > 0.5 else { return }

        var frame = self.frame
        frame.size.height = height
        super.setFrameSize(frame.size)
    }

    private func updateEdgeFade() {
        self.wantsLayer = true
        self.edgeFade.frame = self.bounds
        if self.layer?.mask !== self.edgeFade {
            self.layer?.mask = self.edgeFade
        }

        let width = max(self.bounds.width, 1)
        guard abs(width - self.fadedWidth) > 0.5 else { return }
        self.fadedWidth = width

        // Leading ramp (clear to opaque), the opaque middle, then the mirrored trailing ramp.
        let band = min(Self.fadeWidth, width / 2) / width
        var colors = Self.fadeRamp.map { NSColor.black.withAlphaComponent($0.alpha).cgColor }
        var locations = Self.fadeRamp.map { NSNumber(value: $0.position * band) }
        let middleEnd = NSNumber(value: 1 - band)
        for stop in Self.fadeRamp.reversed() {
            colors.append(NSColor.black.withAlphaComponent(stop.alpha).cgColor)
            locations.append(NSNumber(value: 1 - band + ((1 - stop.position) * band)))
        }
        // The opaque middle sits between the leading ramp's end and the trailing ramp's start.
        colors.insert(.init(gray: 0, alpha: 1), at: Self.fadeRamp.count)
        locations.insert(middleEnd, at: Self.fadeRamp.count)

        self.edgeFade.colors = colors
        self.edgeFade.locations = locations
    }

    /// The compositional layout gives every orthogonal shelf its own scroll view, and those are not the
    /// page's: they arrive with an opaque window-background fill — a rectangle a shade off the page
    /// behind each row — and their own horizontal scroller, which drew a track along the bottom of every
    /// shelf. A section has no setting for either, so the views are configured as the layout adds them.
    private var configuredShelfScrollViewCount = -1

    private func configureShelfScrollViews() {
        guard self.configuredShelfScrollViewCount != self.subviews.count else { return }
        self.configuredShelfScrollViewCount = self.subviews.count
        for subview in self.subviews {
            for case let scrollView as NSScrollView in [subview] + subview.subviews {
                scrollView.drawsBackground = false
                scrollView.backgroundColor = .clear
                scrollView.contentView.drawsBackground = false
                // A shelf scrolls with the trackpad and the wheel; a drawn track under every row is
                // noise, and the page's own vertical scroller already says where the reader is.
                scrollView.hasHorizontalScroller = false
                scrollView.autohidesScrollers = true
                scrollView.scrollerStyle = .overlay
            }
        }
    }
}

// MARK: - HomeFeedCollectionViewController

@available(macOS 26.0, *)
@MainActor
final class HomeFeedCollectionViewController: NSViewController {
    private let environment: HomeCardEnvironment
    private let collectionView = HomeCollectionView()
    private var dataSource: NSCollectionViewDiffableDataSource<HomeFeedSection, HomeFeedItem>?
    /// The sections the layout must answer for, in order. The layout provider is handed an index, not
    /// an identifier, so the order the snapshot applied is kept here.
    private var sectionKinds: [HomeFeedSection] = []
    private var sections: [HomeSection] = []
    private var onSelect: ((HomeSectionItem) -> Void)?
    private var hasAppliedSnapshot = false


    init(
        client: any YTMusicClientProtocol,
        playerService: PlayerService,
        likeStatusManager: SongLikeStatusManager,
        libraryViewModel: LibraryViewModel?
    ) {
        self.environment = HomeCardEnvironment(
            client: client,
            playerService: playerService,
            likeStatusManager: likeStatusManager,
            libraryViewModel: libraryViewModel
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HomeFeedCollectionViewController is not loaded from a nib")
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
            HomeCardItem.self,
            forItemWithIdentifier: HomeCardItem.reuseIdentifier
        )

        scrollView.documentView = self.collectionView
        self.view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.makeDataSource()
    }

    /// Applies `sections`. Called on every page render, so it does nothing unless the feed changed.
    func update(sections: [HomeSection], onSelect: @escaping (HomeSectionItem) -> Void) {
        // The first update can arrive before the view is loaded; the snapshot needs the data source,
        // which `viewDidLoad` builds.
        self.loadViewIfNeeded()

        self.onSelect = onSelect
        guard sections != self.sections else { return }
        self.sections = sections

        let snapshot = HomeFeedSnapshot.make(sections: sections)
        self.sectionKinds = snapshot.sectionIdentifiers
        self.collectionView.declaredContentHeight = Self.contentHeight(for: sections)
        self.dataSource?.apply(snapshot, animatingDifferences: self.hasAppliedSnapshot)
        self.hasAppliedSnapshot = true
        // The order can change without the collection view asking for a layout, and the provider
        // answers header-vs-shelf from that order.
        self.collectionView.collectionViewLayout?.invalidateLayout()
        self.collectionView.fitDocumentToLayout()
        self.collectionView.needsLayout = true

        DiagnosticsLogger.ui.debug(
            "Home feed: \(sections.count) sections, declared content height \(Self.contentHeight(for: sections), privacy: .public), measured \(self.collectionView.collectionViewLayout?.collectionViewContentSize.height ?? 0, privacy: .public), document \(self.collectionView.frame.height, privacy: .public)"
        )
    }

    /// What the sections need vertically: a title row (30 pt + 16 above + 10 below) and a card slot,
    /// per shelf. Mirrors the layout constants in `section(at:)` and `shelfSection(itemCount:)`.
    private static func contentHeight(for sections: [HomeSection]) -> CGFloat {
        sections.reduce(0) { height, _ in
            height + 56 + HomeCardItem.slotHeight
        }
    }

    private func makeDataSource() {
        self.dataSource = NSCollectionViewDiffableDataSource<HomeFeedSection, HomeFeedItem>(
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

            case let .card(_, content, rank):
                guard let card = collectionView.makeItem(
                    withIdentifier: HomeCardItem.reuseIdentifier,
                    for: indexPath
                ) as? HomeCardItem else { return nil }
                card.configure(content: content, rank: rank, environment: self.environment) { [weak self] selected in
                    self?.onSelect?(selected)
                }
                return card
            }
        }
    }

    // MARK: - Layout

    private func makeLayout() -> NSCollectionViewCompositionalLayout {
        let configuration = NSCollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = .vertical
        // Zero: each title's own insets are the only space between shelves, so the gap above a
        // title is one number rather than two stacked ones.
        configuration.interSectionSpacing = 0

        return NSCollectionViewCompositionalLayout(sectionProvider: { [weak self] index, _ in
            guard let self else { return Self.shelfSection(itemCount: 0) }
            return self.section(at: index)
        }, configuration: configuration)
    }

    private func section(at index: Int) -> NSCollectionLayoutSection {
        guard index < self.sectionKinds.count else { return Self.shelfSection(itemCount: 0) }

        switch self.sectionKinds[index] {
        case .header:
            let size = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .absolute(30)
            )
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            // The page's own top padding lives on the first title, since the collection view
            // insets its sections rather than its content.
            section.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 10, trailing: 24)
            return section

        case .items:
            return Self.shelfSection(itemCount: self.itemCount(for: self.sectionKinds[index]))
        }
    }

    /// A shelf: cards of one size, laid out continuously along the horizontal axis.
    ///
    /// One group, sized to exactly the cards it holds. A fractional-width group fills the page and
    /// then starts a new group for the rest, which left the width the last group could not use as a
    /// bare gap in the middle of the shelf — the shelf looked like it skipped a card every screen.
    private static func shelfSection(itemCount: Int) -> NSCollectionLayoutSection {
        let spacing: CGFloat = 0
        let count = max(itemCount, 1)
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .absolute(HomeCardItem.slotWidth),
            heightDimension: .absolute(HomeCardItem.slotHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .absolute((CGFloat(count) * HomeCardItem.slotWidth) + (CGFloat(count - 1) * spacing)),
            heightDimension: .absolute(HomeCardItem.slotHeight)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitem: item, count: count)
        group.interItemSpacing = .fixed(spacing)

        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = spacing
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24)
        return section
    }

    /// How many cards the shelf with this identifier holds.
    private func itemCount(for section: HomeFeedSection) -> Int {
        guard case let .items(id) = section else { return 0 }
        return self.sections.first(where: { $0.id == id })?.items.count ?? 0
    }
}

// MARK: - HomeCardItem

/// A recycled cell hosting one card.
@available(macOS 26.0, *)
@MainActor
final class HomeCardItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("HomeCardItem")

    /// The card itself, and the room around it for the hover scale and shadow (ADR-0045's bleed).
    ///
    /// A hosting view clips to its own bounds, so a slot the size of the card cropped the shadow and
    /// the 1.02 scale exactly at the card's edge — the card appeared to lose its border on hover. The
    /// slot carries the bleed instead, and the shelf's item spacing is 0: the gap between two cards is
    /// the two bleeds.
    static let cardWidth: CGFloat = 160
    static let cardHeight: CGFloat = 224
    static let bleed: CGFloat = 10
    static var slotWidth: CGFloat { self.cardWidth + (2 * self.bleed) }
    static var slotHeight: CGFloat { self.cardHeight + (2 * self.bleed) }

    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    override func loadView() {
        self.view = self.hostingView
    }

    func configure(
        content: HomeSectionItem,
        rank: Int?,
        environment: HomeCardEnvironment,
        onSelect: @escaping (HomeSectionItem) -> Void
    ) {
        self.hostingView.rootView = AnyView(
            HomeCardCellContent(
                item: content,
                rank: rank,
                environment: environment,
                onSelect: onSelect
            )
        )
    }
}

// MARK: - HomeCardCellContent

/// The SwiftUI content of one card cell: the card, its context menu, and nothing else.
@available(macOS 26.0, *)
private struct HomeCardCellContent: View {
    let item: HomeSectionItem
    let rank: Int?
    let environment: HomeCardEnvironment
    let onSelect: (HomeSectionItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeSectionItemCard(item: self.item, rank: self.rank) {
                self.onSelect(self.item)
            }
            .contextMenu {
                HomeCardMenuContent(
                    item: self.item,
                    client: self.environment.client,
                    likeStatusManager: self.environment.likeStatusManager,
                    playerService: self.environment.playerService,
                    libraryViewModel: self.environment.libraryViewModel
                )
            }

        }
        .padding(HomeCardItem.bleed)
        .frame(width: HomeCardItem.slotWidth, height: HomeCardItem.slotHeight, alignment: .topLeading)
    }
}

// MARK: - HomeFeedHeaderItem

/// A shelf's title, drawn by AppKit: a label has no reason to be a hosted SwiftUI tree.
@available(macOS 26.0, *)
@MainActor
final class HomeFeedHeaderItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("HomeFeedHeaderItem")

    private let titleField = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView()
        self.titleField.translatesAutoresizingMaskIntoConstraints = false
        self.titleField.font = .systemFont(ofSize: 22, weight: .semibold)
        self.titleField.textColor = .labelColor
        self.titleField.lineBreakMode = .byTruncatingTail
        container.addSubview(self.titleField)
        NSLayoutConstraint.activate([
            self.titleField.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            self.titleField.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            self.titleField.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.view = container
    }

    func configure(text: String) {
        self.titleField.stringValue = text
    }
}
