# ADR-0051: A Card Opens into a Page by Growing

## Status

Accepted

## Context

The Now Playing sidebar's overview is made of two glass cards — the lyric window and the up-next
row — and each one opens a full page in the same column: the lyric sheet, the queue. The two pages
are different views of different data, drawn at a different size, and the swap between them used to
be a cut: the overview disappeared and the page appeared, in one frame.

A cut is visible in exactly the way this design cannot afford. The column is one surface made of the
album's own blur ([ADR-0029](0029-now-playing-sidebar.md)), and the reader's eye is on the card they
clicked; if the card's contents vanish and a page appears, the column reads as two screens that were
swapped rather than as one that opened.

Three properties were required:

1. **No frame may show the page at its full size before the card has been measured and drawn.** That
   is the flash every "animate the change" transition leaves behind: the tree is re-evaluated with the
   new page, the change handler then prepares the animation, and the frame in between is already wrong.
2. **The page must not re-lay out while it moves.** Laid out at the card's size and grown from there,
   the queue's `NSTableView` would re-column itself on every frame and the lyric sheet would re-wrap
   every line — the content would crawl, and no amount of easing hides it.
3. **Nothing may be drawn outside the card's own shape on the first frame** — a page revealed through a
   square clip in the corner of a 16pt-rounded card is visible immediately.

## Decision

**The card's rect is the window, and the window is a masked shape.** The page is drawn at its final
size and position from the first frame; a single `Shape` whose only animated value is the move's
progress masks it, growing from the card's rect (with the card's corner radius) to the whole column
(and square). Growing the mask instead of the page's frame is what keeps the page from re-laying out,
and animating one shape's `animatableData` is what keeps the rect, the rounding, the fades and the
page's settle on one curve instead of four that can drift.

`NowPlayingSidebarCardExpansion` holds the move (which page, which way, the card's rect, its rounding,
a generation), `NowPlayingSidebarExpansionWindow` is the shape, and the column draws two layers for
the length of the move: the overview under it and the page in it, with opacities that always sum to
one. The layer in the window holds **the page the move is about** — the page arriving, or, while one
closes, the page that is leaving (`windowPage`) — so a closing is the same move backwards rather than
a swap, and the page is never rebuilt at the instant it starts to leave.

**The column draws its own copy of the page state.** `presentedPage` trails
`PlayerService.nowPlayingSidebarPage` by the update in which the move is prepared, and
`pageDidChange(from:to:)` is the single funnel every change goes through — a card's click, the
transport's buttons, the toolbar's back control. This is what makes property 1 structural rather than
timing-dependent: the body never reads the service's page, so the frame that arrives with the change
cannot show it. A transition that reacted to the change (`.onChange` alone, with the body reading the
service) is one frame late by construction, and that frame is the flash.

**An opening starts one update after its page mounts.** A shape that did not exist in the previous
committed update has nothing to interpolate from: it is drawn at the end of the move and the page
simply appears. `startExpansionIfPending` lets one frame at the card's size go by before growing
(`.onAppear`, plus a one-millisecond pause because `onAppear` can also run inside the mounting
update). The closing direction needs no pause — its window is already on screen at full size.

**The geometry is measured, not derived.** The cards report their rect in the column's own coordinate
space (`onGeometryChange`, into `NowPlayingSidebarCardWindows` — a reference box, so a scroll of the
overview does not re-evaluate the column). The card's y is a function of the artwork's height, the
title's line count and the scroll position; only the layout knows it.

**What the platform allows was measured, not assumed.** In a hosted probe over an AppKit view:
`.clipShape` does **not** clip AppKit-hosted content (a 300×300 `NSTableView`-style view stayed
300×300 inside a 100×100 clip), while `.clipped()` and `.mask` do, and `.scaleEffect` does transform
it. The queue page is AppKit, so `.mask` is the only clip that can carry it — which is why the page
layer carries the window shape permanently (an identity rect at rest) rather than gaining and losing a
mask: a conditional `.mask` changes the view's structure, and dropping it at the end of the move would
rebuild the queue's table and reset its scroll at the exact moment the reader starts looking at it.

**Reduce Motion is obeyed by omission**: with the system setting on, no window is installed and the
page changes as it did before.

## Consequences

- The two pages are never swapped in view. What moves is the card's shape, and it moves from the
  reader's card to the column's own bounds.
- A page change that has no card behind it — a page opened from the transport when the column has just
  appeared, the transcript page (which is an inline card, not a page card), one page replaced by
  another — is still drawn immediately. There is nothing to grow out of, and inventing a rect would
  look worse than a cut.
- A move that is interrupted (the reader closes the page mid-spring) is landed rather than re-animated:
  the column cannot read where its window is mid-spring, and starting from the previous move's end
  point would jump the card across the column.
- The page layer is always masked, so the queue's AppKit table is composited through a mask. Measured
  to draw correctly; its interactive scrolling was not measured.
- `AppAnimation.cardExpansion` is the curve: a 0.30 s spring, damped to 0.88 so the window cannot
  bounce past the column's edges.
- What could **not** be measured here: the move over time. SwiftUI animations are driven by the
  display link, and a hosted test cannot run one (a control animation held in a visible window did not
  complete in 1.6 s, and rendering the layer tree reads committed values, not the presentation's), so
  neither the timing nor the look has been observed by an agent. The column states both ends of every
  move on the `ui` log — `Card expansion started: <page> <direction> window=…` and
  `Card expansion landed: <page> in <n>ms` — which is what to read to tell a move that ran from one
  that landed at once.
