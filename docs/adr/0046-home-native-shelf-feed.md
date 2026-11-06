# ADR-0046: Home's Feed as One Native Collection View

## Status

Accepted

## Context

Home was a vertical SwiftUI `ScrollView` over a `LazyVStack` of shelves, and every shelf was another
`ScrollView` — a horizontal one — of cards. On macOS that is a dozen `NSScrollView`s nested inside a
scrolling page, each shelf drawing through a mask to soften its trailing edge (an offscreen pass over
every card in the row), and each card a SwiftUI `Button` whose body the page re-evaluates whenever it
re-renders. Continuations append sections four times after the first paint, and every append re-rendered
the page.

This was addressed twice from inside that composition — decoding artwork at slot size, suspending hover
under the pointer — and neither changed how Home scrolls. The remaining cost is structural: nested scroll
hosts, a mask per shelf, and a live view tree per card. Home is the one page in the app made entirely of
shelves, so it is the one page that shape is wrong for.

## Decision

Home's feed is a single AppKit `NSCollectionView` (`HomeFeedCollectionView`, a
`NSViewControllerRepresentable`) with an `NSCollectionViewCompositionalLayout`:

- one `NSScrollView` for the page; shelves use `orthogonalScrollingBehavior = .continuous`, so the
  horizontal scrolling is AppKit's own rather than a nested SwiftUI scroll view's;
- items are absolute 180 × 244 slots holding a 160 × 224 card, so cells are recycled and only what
  is on screen exists. The 10 pt bleed around the card is the room its hover scale and shadow draw
  into: a hosting view clips at its own bounds, so a slot the size of the card cropped both;
- the collection view clips its content, which replaces the per-shelf mask;
- a shelf's title is a **section of its own** (`.header(id:)`) rather than a boundary supplementary item.
  A supplementary item belongs to the shelf's orthogonal container and would scroll away sideways with
  the cards; as a section it sits in the page's vertical stack;
- cards keep their SwiftUI body (`HomeSectionItemCard`, hover and context menu unchanged) inside a
  recycled `NSHostingView`. The hosting root is its own SwiftUI environment, so the page's services are
  passed in explicitly (`HomeCardEnvironment`);
- titles are `NSTextField`-drawn cells: a label does not need a hosted tree.

The diffable snapshot is built by a pure `HomeFeedSnapshot.make(sections:)`, whose identifiers include
the shelf id and the card's position — one feed can show the same song in two shelves, and duplicate item
identifiers crash a diffable snapshot. A snapshot is applied only when `sections` actually changed.

## Consequences

### Easier

- One scroll view for the page instead of one per shelf; cell reuse instead of a persistent card tree.
- No mask pass per shelf: clipping is the layout's, not a per-frame offscreen render.
- A Home card's body is no longer re-evaluated because a shelf elsewere on the page changed.

### Harder / given up

- **Home's edge fade is page-wide, not per shelf.** It cannot react to each shelf's horizontal offset:
  it fades both edges whenever content runs under them, so a shelf that fits inside the page has an
  invisible fade in its padding. The band is 24 pt — the sections' own inset — which is what keeps a
  short shelf's first and last card at full opacity. Every other page keeps `HorizontalRowEdgeFade`,
  which can fade an edge only while it is really hiding content because it owns one row.
- The mask lives on the collection view, not the scroll view's clip view. A clip-view mask is sized by
  hand, and one sized early made everything below it transparent: the page stopped part-way down.
- Cards are sized by the layout (160 × 224) rather than by their content; a one-line title leaves the
  remainder of the slot empty.
- Home's interaction details now live in AppKit-hosted cells. Hover, context menus and the play badge
  still come from the SwiftUI card, but anything added to the page (selection, drag, keyboard focus) has
  to be wired through the collection view.
- `HomeView` no longer prefetches a shelf's first thumbnails: only realized cells load artwork.
- A collection view used as a representable's document view is not grown by AppKit, so
  `HomeCollectionView` sets the document height from its own layout on every layout pass; without
  that, Home scrolled one screen and stopped.
