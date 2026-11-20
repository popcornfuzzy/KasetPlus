# ADR-0056: Overlapping Word-by-Word Lines

## Status
Accepted

## Context

`SyncedLyrics` is a list of lines, and `KaraokeFillModel.lineChanges` gives each one a single
moment — its *baton* — at which it becomes the line being sung. The display treated that as an
invariant: exactly one row was `.current`, and every other row was `.previous` or `.upcoming`.
That is right for a sheet read one line at a time.

Providers do not always write one line at a time. A duet can put both singers' paragraphs on the
same stretch of time, and a TTML paragraph's words can run past the next paragraph's `begin`
because its `end` is its own. `TTMLParser` keeps each `<p>` with its own window, so such a sheet
genuinely has two lines sounding at once. The baton still moved to the later line, and the earlier
row — which was still filling word by word — was immediately drawn as `.previous`: 35% opacity,
scaled down, its Better Lyrics letters put back on the baseline. A line that was plainly still
being sung looked finished.

## Decision

Each `KaraokeLineChange` carries the moment its line **stops sounding** (`endMs`): its own
`settleBoundaryMs`, or, for a row with nothing to sing, the next row's baton. A line is being
sung between its baton and that end, and `activeLineIndices(in:at:)` returns every line whose
window contains the position — usually one, two when they overlap.

- `status(forLineAt:highlightIndex:activeIndices:)` makes every active row `.current`. Rows above
  the highlight that are no longer sounding stay `.previous`, and rows below stay `.upcoming`.
  The highlight itself — the newest baton — is unchanged, so the scroll target and the normal
  hand-off are unchanged.
- `isLiveRow` puts every active row on the display clock, wherever it sits relative to the
  highlight. Both overlapping rows keep filling instead of the older one freezing at its settled
  frame.
- `KaraokeFrameBudget` gives each active row the live rate, because both are being watched.
- `nextChangeMs` also wakes at a line's `endMs`, so the older row dims on the moment it stops
  sounding rather than up to a 10 Hz sample later.
- A row with nothing to sing is still silence: its window starts at its baton, which waits for
  the line above's lead and backing to settle. Overlap never makes the pause dots current under a
  line that is still sounding.

## Consequences

Overlapping word-timed lines now animate together, which is what the music does. Sheets that never
overlap are unchanged: one active row, one highlight, the same transitions, plus one extra
scheduled wake-up per line at its own settle moment.

The model now has a second time per line to keep in step with the baton. Both are derived in
`lineChanges` from the same `settleBoundaryMs`, so a change to what "settled" means cannot make
them disagree.
