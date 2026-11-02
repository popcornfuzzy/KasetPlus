# ADR-0041: The Hand-Queued Run (Spotify-Style Two-Tier Queue)

## Status

Accepted

## Context

`PlayerService` holds one `queue: [Song]` plus a `currentIndex`. "Play Next" inserted directly under
the playing row (`insertNextInQueue`), and "Add to Queue" appended to the **end** of that same array
(`appendToQueue`). Starting an album or playlist therefore put every hand-added song after the album's
last track — the opposite of what a reader expects from Spotify, where "Add to Queue" builds a separate
"Next in queue" list that plays before the playlist itself resumes, in the order the songs were added.

The queue is also not private to Kaset: the hidden WebView's page reports track changes, moves the
playhead and appends its own autoplay rows, and every one of those paths writes `currentIndex` and
`queue`. A second data structure (two arrays, or a queue of tagged entries) would have to be kept in
sync with every one of those writes and with persistence, undo, drag-reorder and removal — the places
where a split model normally drifts.

## Decision

**The queue stays one array; a count describes which of its rows were added by hand.**

- `PlayerService.manualQueueCount` is the number of hand-queued rows forming the contiguous run
  directly below the playing row: `currentIndex + 1 ..< currentIndex + 1 + manualQueueCount`
  (`manualQueueRange`).
- `insertNextInQueue` ("Play Next") inserts at the front of that run; `appendToQueue` ("Add to Queue")
  inserts at its end. Both lengthen the run. An empty queue takes the songs as the whole queue.
- **Consumption is an observer on `currentIndex`.** Moving forward trims the run by the number of rows
  passed, moving back starts it empty. This is what makes the rule hold for every advance — `next()`,
  a natural track end, `playFromQueue(at:)`, shuffle, repeat-all, and the WebView's own realignment —
  without any of those paths knowing the run exists. Moving back leaves the array order untouched, so
  playback still walks the same songs; only where the *next* hand-queued song goes changes.
- **A new queue clears the run.** Every path that loads songs (`playQueue`, radio, mix, tuning,
  rollover, autoplay sync, episode playback, clear) sets the count to zero, because hand-queued rows
  belonged to the queue they were added to.
- **Removal adjusts it; a drag does not.** Removing a row inside the run shrinks the count. A drag is a
  move and nothing else, so every row can be dropped anywhere the playing row is not in the way. The run
  is then purely a *position* — the rows under the playing row — and a row is filed by where it landed:
  a playlist row dragged into the run pushes the run's last row out to the playlist, and a hand-queued
  row dragged below it pulls the playlist's first row in. There is no classification rule, no caption to
  aim at and no exception for a row dropped in the gap it already stands in (that drop moves nothing and
  is refused, so nothing re-files). Shuffling resets the run — the shuffle deals hand-queued rows among
  the playlist's.
- **The boundary is a position, not a rule.** The gap under the run's last row *is* the gap above the
  playlist's first row. Earlier revisions gave that one gap a section of its own and read the drop's
  intent from the rows being moved, then from which half of the caption the drop landed on; both made
  ordinary moves behave differently from the place they were released in, and the boundary gap is one
  pixel range either way. The run is a position instead: which rows are hand-queued is decided by the
  count alone, so a drop only has to say *where*. The cost is that a drop inside the run's slots can
  change which songs are hand-queued; the benefit is that every row is draggable to every place, which
  is the interaction the reader asked for.
- **The run can be emptied in one action.** `clearManualQueue()` removes every row between the playing
  row and the playlist's first row, undoably; both queue surfaces put its trash button on the
  "Next in queue" caption's line.
- **The run survives undo, redo and relaunch.** Undo snapshots carry the count, and
  `PersistedPlaybackSession.manualQueueCount` (optional, so older sessions still decode) restores it
  with the queue.

## Consequences

- "Add to Queue" now behaves like Spotify: the first add lands directly under the playing row, the next
  one below it, and the playlist resumes after them. "Play Next" still jumps the line, now above the
  songs already added to the queue.
- The invariant lives in one place — the `currentIndex` observer — so page-driven moves cannot leave it
  stale. The count is only the *insertion point*: the array remains the single source of truth for what
  plays next, so a stale or cleared count can misplace a future add but cannot reorder or drop a song.
- Both queue surfaces label the split: the first hand-queued row opens a **Next in queue** section and
  the playlist's first remaining row opens **Rest of the queue**. The captions appear only when a run
  exists, so a queue nothing was added to looks as it did.
- In the AppKit list a caption is a **row of its own** — an `NSTableView` group row drawn by
  `QueueSectionHeaderCellView`. Group rows are full width, not selectable and not draggable, and they
  are inseparable from the queue rows in a drag: the drag image is a snapshot of one row, so a caption
  can never ride along with a song. The table therefore indexes *its own* rows (captions included),
  and the coordinator maps those to queue indices (`queueIndex(forTableRow:)`,
  `tableRow(forQueueIndex:)`, `queueDestination(forTableRow:)`) for playback, swipe-to-remove, the
  context menu, auto-scroll, drag payloads and drop destinations. The SwiftUI popup draws the same two
  captions as views between its rows.
- A playlist reloaded in place (tuning, rollover, radio refresh) drops the hand-queued rows along with
  the old upcoming songs; that is the same replacement the queue already performed.
- The captions do not float (`floatsGroupRows = false`). A floating group row is drawn above the list
  and is carried along with the rows a drag opens a gap in, so the caption under the pointer slid around
  with the song in hand; a caption that scrolls with its own section has nothing to follow.
- A drop installs its result in the table **inside `acceptDrop`**: `onReorder` hands the reordered queue
  back (`QueueTableState`) and the coordinator applies it there, because AppKit settles the session
  against the data source as that call returns. Waiting for the model's SwiftUI update instead drew the
  old order for a frame and then jumped to the new one, and reloading rows mid-drag rearranged them
  under the pointer. The coordinator reloads only when the rows actually changed, so the update that
  follows the drop is a no-op. The drop itself reloads, and that is deliberate: re-pointing the surviving
  row views at their new songs instead made the list glide — AppKit is still easing those views out of
  the gap it opened for the drag while `acceptDrop` runs, so a view that changes song mid-flight slides
  one way while its contents change the other. A reload ends that motion.
- The reload used to *cost* something: every row view went back to the reuse pool, whose
  `prepareForReuse` clears the thumbnail, and the list wore empty artwork for the frames the cached
  images took to return — brief, and only sometimes, which is the kind of flicker that is hard to
  attribute. The fix is in the row, not the drop: `QueueTableCellView.configure` seeds its image
  synchronously from the memory cache before asking for one, so a rebuilt row draws with its picture
  in the same frame. A row starts empty only when the app genuinely has no decode of that artwork yet.
