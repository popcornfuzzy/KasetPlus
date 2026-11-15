# ADR-0050: The Podcasts Page on the Native Shelf Feed

## Status

Accepted

## Context

[ADR-0046](0046-home-native-shelf-feed.md) moved Home's feed off a vertical `ScrollView` of nested
horizontal `ScrollView`s onto one `NSCollectionView` with orthogonal shelf sections. The podcasts
discovery page kept the old composition: a vertical `ScrollView` over a `LazyVStack` of shelves, each
shelf its own horizontal `ScrollView` with `HorizontalRowEdgeFade`'s mask. It scrolled noticeably worse
than Home for the same structural reasons ADR-0046 lists, and its `LazyHStack` sized a row from the first
card it realised, so a card with a wrapped title was clipped and a shorter card sat off its neighbours'
line — a bug that took two measured attempts to explain and could not be fixed reliably from inside that
composition.

The podcasts shelves differ from Home's in one way that matters to a layout: a shelf can hold two card
kinds. Episode cards are 200 × 176 (112 pt artwork) and show cards 160 × 224 (160 pt artwork), and the
parser can put both in one section.

## Decision

The podcasts page's shelves are `PodcastFeedCollectionView`, the same construction as Home's feed:

- one `NSCollectionView` (`ShelfFeedCollectionView`, the class both feeds now share) with an
  `NSCollectionViewCompositionalLayout`; shelves scroll orthogonally (`.continuous`);
- a shelf's title is a section of its own, as in ADR-0046, so it does not scroll sideways with the cards;
- cards keep their SwiftUI bodies (`PodcastShowCard`, `PodcastEpisodeCard`) inside recycled cells;
- the diffable snapshot comes from a pure `PodcastFeedSnapshot.make(sections:)` whose identifiers carry
  the shelf id and the card's position.

A shelf's group is built with `NSCollectionLayoutGroup.custom`: the frames are placed by hand from each
card's slot width, at one group height — the shelf's tallest card. A fixed-count or fractional group
would force one item width on a shelf that mixes kinds, and would leave a partial group's unused width as
a bare gap mid-shelf.

Slot sizes are constants (`PodcastFeedMetrics`), as Home's are, and `PodcastFeedTests` measures the real
cards at their slot width and fails if one grows past its slot's height — the clipping ADR-0045's bleed
and this layout would otherwise reintroduce.

## Consequences

- The page has one scroll view, no per-shelf mask, recycled cells, and cards start on one line by
  construction: a slot is a fixed size, so a one-line title cannot make a card shorter than its row.
- The edge fade is the collection view's page-wide band (24 pt) rather than a per-shelf mask. A shelf
  that fits inside the page has an invisible fade in its padding — the trade ADR-0046 already made on
  Home.
- Cards are sized by the layout, not their content: a one-line title leaves the rest of its slot empty,
  so the date line is not on one baseline across a row.
- `PodcastSectionItem` still compares by id alone, so `PodcastSection` equality — and therefore the
  feed's "did this change?" check — ignores an episode's playback progress changing in place. The page
  reloads its sections on refresh, which is when progress is read.
- `HomeCollectionView` was renamed `ShelfFeedCollectionView` because two pages now use it; its behaviour
  is unchanged.
