# ADR-0045: Softened Horizontal Row Edges

## Status

Accepted

## Context

Every shelf in the app — Home, Explore, Charts, New Releases, Moods & Genres, a
mood's page, Podcasts, artist pages, Search's "Jump back in" — is a horizontal
`ScrollView` of cards laid out inside a page that pads its content by 24 pt. A row with more cards than fit ends in a hard vertical cut exactly where
the page's trailing edge meets the Now Playing column: the next card is visible
for half its width and then simply stops. At night that reads as a shelf glued
to the column; in light mode, where the cards' trailing edges fade into a white
page, it reads as a white band down the side of the window.

The look being copied is Spotify's: content carries on *under* a soft edge and
dissolves as it approaches the column, so there is no seam at all.

Two ways of drawing that were rejected:

- **A gradient painted in the page's colour.** Cheap, and wrong the moment the
  page is not one colour — the detail pages draw an artwork-derived accent
  gradient behind their content (see `AccentBackground`), and light and dark
  surfaces differ. A fixed colour would have made a visible band over exactly
  the pages it was meant to soften.
- **A static mask** that always fades the trailing edge by a fixed width. This
  dims shelves that never overflow (two albums, a couple of singles) and dims a
  card that is fully visible at the end of a row, so it lies about what is
  under it.

## Decision

One modifier, `HorizontalRowEdgeFade` (`Views/SharedViews/HorizontalRowEdgeFade.swift`),
applied to every horizontal card row:

- **It is a mask, not paint.** A black-to-clear ramp removes the content's
  alpha, and whatever is behind the row shows through. Pages keep their own
  surface.
- **The fade is the last stretch of the row's remaining content.** The widths
  come from the scroll view's own geometry (`onScrollGeometryChange`): the
  trailing fade is capped at the row's overflow (`contentSize - containerSize -
  offset`), the leading fade at the offset. Nothing overflows, nothing fades;
  a row scrolled to its end stops fading, and the fade tapers as it gets there
  instead of switching off. Only the clamped widths are published, so scrolling
  through the middle of a long row re-renders nothing.
- **The leading edge fades only once the reader has scrolled.** At rest the
  first card is whole, so fading its edge would claim content that is not there.
- **Mostly-opaque ramp.** A straight `black`→`clear` ramp over the same width
  read as a wash over the cards; the stops hold near-full opacity through the
  first half and dissolve only at the edge (32 pt default).
- **The row is widened into its page's padding.** The trailing fade has to be
  drawn at the window's edge, where the column starts, not 24 pt inside it. The
  modifier takes the page's own inset (`pageInset`, 24 pt in every page that
  uses it) and widens the row by it outside the mask, so the mask reaches the
  page edge while the row still reports the width the page gave it. This was
  the first bug in the feature: masking inside the page padding left the card
  cut short *and* the padding bare, which is a white band, not a dissolve.
- **`.contentMargins(.trailing, pageInset, for: .scrollContent)` gives the row's
  end its inset back**, so a shelf scrolled all the way keeps its last card
  clear of the column exactly as it did before the fade existed.
- **Hover is suspended while the row scrolls.** The modifier publishes `rowIsScrolling` into the
  environment and the cards it holds pass `isHoverEnabled: false` to `InteractiveCardStyle` while
  it is true, so a card travelling under a stationary pointer does not start scale, shadow and
  material work mid-flick. This is the rule ADR-0014 applies to list rows, where hover tracking was
  measured at 12–15% of main-thread samples; on a shelf it is even more clearly wasted work, since a
  card that slides under the pointer was not being pointed at.
- **Hover bleed: the mask is given 20 pt of headroom.** A mask clips to its own
  bounds, and a row's bounds are exactly its cards, so the hovered card's
  `interactiveCard` scale and 12 pt shadow were sliced off along the row's top,
  bottom and leading edges. The mask is padded by 20 pt on those sides and the
  padding is taken back outside it: rows lay out at the size the page gave them,
  cards stay where the page put them, and only the drawing (and the mask's edge)
  extends — vertically into the row spacing, and on the leading side into the
  page's own leading padding, which is the only room the first card has to grow
  into. The leading fade is lengthened by that bleed so it still reaches full
  opacity the same distance into the first card.

## Consequences

- One line per row (`.horizontalRowEdgeFade()`) covers the whole app, including
  rows added later; a row in a page with different padding passes
  `pageInset:` rather than the modifier assuming 24.
- Rows are rasterized for the mask, which costs an offscreen pass per row while
  it scrolls. The state only changes at the edges of a row's travel, and the
  mask is otherwise a rectangle, but this is a real cost against the previous
  un-masked scroll view.
- On the first layout pass the geometry is not known yet, so a row renders one
  frame without a fade before its overflow arrives.
- The trailing edge of a hovered card that sits right at the column is still
  clipped: the mask has to end at the page edge for the fade to work. The
  leading edge gets its room from the page padding; there is none on the right,
  because that is where the fade lives.
- The shelves' cards now pass `targetSize` to `CachedAsyncImage` (`ImageCache` doubles it for
  Retina): a 160 pt card decodes 320 px instead of the 640 px its default target produced, and the
  same was fixed for the podcast and artist-page cards. Decode work was already being
  paid on the scroll path for cold artwork, which is the second of ADR-0014's five costs.
- The scroll-phase watch lives on the row, so a row inside a page that is itself scrolling (a
  vertical page scroll under the pointer) does not suspend hover: only the row's own horizontal
  gesture does.
- The fade needs the row to *be* a scroll view. Content that scrolls some other
  way (a `LazyHGrid`, a paged control) gets nothing from the modifier and would
  have to feed `HorizontalRowEdgeFade.EdgeFades` itself if it wants the same
  treatment.
- Nothing here is API or data: no request, cache or model is involved, so the
  fade is invisible to tests. It is verified by eye in both appearances.
