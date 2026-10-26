# ADR-0037: In-Page Track Changes Instead of Watch-Page Navigations

## Status

Accepted

## Context

Every track change in Kaset was a page navigation. `next()`, `previous()`, a queue click, a natural
track end — all of them ended in `webView.load(watchURL)`, which throws the document away and pays for
the whole YouTube Music boot again: JS bundle, service worker, player construction, DRM handshake, and
the first render of the player bar. The bar's loading strip exists because that wait is seconds long.

The page already has a player in it. It can start another track without reloading the document, and
that is the same transition YouTube Music itself makes when its own queue advances.

An earlier version of this work went further: it installed Kaset's upcoming rows into the page's own
player queue (and used `nextVideo()` there) so the page would prefetch the next track and advance into
it by itself. That was rejected after using it, because it fought the page:

- YouTube Music's player bar is driven by the page's own queue and store. Installing a foreign queue
  behind its back left the bar describing a track that was no longer playing, so lyrics, the byline and
  the artwork came from the wrong song until something else corrected them.
- At a natural track end the page's own advance and Kaset's install both moved playback, which was
  heard as a song being skipped while the bar still showed the one Kaset had started.

## Decision

Kaset asks the page's player to start **one track**, and leaves the page's own queue, store and UI
alone.

- `SingletonPlayerWebView+PagePlayback` injects a small bridge (`window.__kasetPlayback`). Asked to
  play a track, it answers, in this order: `already-playing` (the player already holds it),
  `played-at` (the page's own queue holds it, so jump to it), `loaded-video` (load it into the open
  document), or `no-player`/`error` (it cannot).
- `loadVideo(videoId:strategy:)` tries that before navigating. A page that cannot, gets the watch page
  — the behaviour Kaset always had.
- `PlayerService+PagePlayback` checks the answer: ~1 s after the start it asks the page which track its
  player holds, and if that is not the track Kaset asked for, it asks once more (`reassert`), and after
  that loads the watch page (`load`). The decision is `WebQueueSettleRules`, which is pure and tested.
- A page that accepts the command but never starts playback is loaded by a 3 s watchdog.
- `PlayerService.pagePlaybackCapability` remembers what this document proved, and `didFinish` resets it
  (a new document is a new player).

Nothing about Kaset's queue changes: `handleTrackEnded`, `next()`, `previous()`, drift correction and
repeat/shuffle all still decide what plays. Only *how* the page starts it changed.

### Why the page's queue is not installed

The page's queue is the page's own state. Kaset's queue is the authority on what should play, and the
two can disagree without anything being wrong — YouTube's queue is filled with autoplay. Sharing rows
with it means either the page moves first (Kaset must then follow it) or Kaset moves first (the page
must be rewritten), and both directions were visibly wrong. One track at a time keeps one queue
meaningful, and keeps Kaset's queue authoritative by construction rather than by correction.

### Metadata that belongs to another track

An in-page swap does not re-render the page, so the player bar can still be describing the previous
track for a moment. The observer now reports the track the bar itself names (`barVideoId`), and
`updateTrackMetadata` refuses a bar that names a different track than the player reports: that text is
not a description of the playing track, and recording it would give the lyrics and byline another
song's metadata. The queue row stays on screen until the page catches up.

The opposite direction needs the same care: a start does not stop the page reporting the track it is
leaving. Those late reports are the previous song, and believing them realigned the queue index *back*
to the row that had just been left and flashed its title on screen until the next report corrected it.
`updateTrackMetadata` therefore ignores an observation of a track left within 3 s
(`PlayerService.departedTrackWindow`), and takes that track off the list if a start lands on it again.

The id alone is not enough: mid-swap the page can pair the new video's id with the outgoing song's
words, which by id looks exactly like a correction of the row. The departed track's text is remembered
with it, and a report carrying those words is ignored as well — except when they are the playing row's
own title, in which case there is nothing to correct and nothing to drop.

A description of the *playing* video is a third case: it can carry the right id with another song's
words, which no id-based rule can see. A trace of the real page showed it plainly — 0.2 s after a
natural advance the page reported the correct new id with a two-tracks-old title, from the bar's DOM,
with no bar link and nothing from the player API, and its real words arrived 1.4 s later. Adopting that
is what briefly put another title on the Now Playing column, a column and a player bar that both render
`currentTrack` and therefore cannot diverge.

So for `startedTrackTextGrace` (2.5 s) after a start, contradicting text is taken only when it is
anchored to the playing video: from the player API's record for it, or from a bar whose link names it.
Otherwise the row Kaset started keeps its words and the lyrics gate stays closed. After the window the
page's words may correct the row again.

### Seeing the next track

The observer used to stop polling the moment a track ended, so whatever played next — the page's own
advance, autoplay — could go unreported and leave the app showing the finished song. It now keeps
reporting for a short tail after `ended` (12 × 1 s), which is what makes an end-of-track transition
visible and correctable.

### A track the page skips by itself

YouTube Music completes its own end-of-track advance *after* it reports `ended`, so the next row Kaset
starts in that gap can be overwritten by an advance already in flight: the new song plays for a moment
and the page moves on to the one after it, while Kaset's bar still shows the song it started. That was
what "dragged the progress bar to the end and it skipped a song" looked like.

The fix is a short window, not more reconciliation: a start that follows a track ending opens
`PlayerService.trackStartGrace` (2.5 s), and inside it a report of another track — or a second `ended`
for the row that just started — is never a queue move. Kaset puts its row back into the page
(`reassertCurrentRowInPage`) and re-checks it, instead of following the page one row too far. A start
the user asked for (play, Next, a queue row) does not open the window, so a deliberate skip right after a
start is still followed.

Separately, a track ending without the media having reached its end (`progress` short of `duration`) is
ignored: a load that kept the old position ends immediately, and that end advanced the queue.

### Position and near-end state

Starting a track resets `progress`, because the position belonged to the song that just ended. Leaving
it meant the player bar showed the old position and, worse, the next metadata observation passed the
"near the end" test and advanced the queue a second time. The near-end handler also advances at most
once per transition (`advanceForNearEndTransition`), because the page reports the same unexpected track
several times as it moves on.

## Consequences

- A skip that stays inside the page costs no document load; a page that cannot take one falls back to
  a navigation, which is the old behaviour.
- YouTube Music's own UI and queue are untouched, so its player bar, its queue panel and Kaset's queue
  panel cannot disagree about which song is playing.
- The prefetch advantage of a shared page queue is gone: the next track is loaded when it is needed,
  not before. That is the price of the page's state staying coherent.
- The bridge is the one place Kaset depends on a page-internal API. It lives in one file, its contract
  is a status string, and `WebPagePlaybackScriptTests` drives it against a mock player.
