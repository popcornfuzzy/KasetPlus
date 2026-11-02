# ADR-0042: One Authority per Question — Where the Transport's Like Status Comes From

## Status

Accepted

## Context

The player bar's thumb was sometimes lit for a song nobody had liked, for the whole song, and no
amount of re-checking corrected it. The rating reached `PlayerService.currentTrackLikeStatus` through
four routes, and each merged with the others by its own rule:

1. **The player bar's like button**, read by the observer script
   (`document.querySelector('ytmusic-like-button-renderer')` → `STATE_UPDATE.likeStatus`).
2. **The row a track was started from** (`Song.likeStatus`; the Liked Music page states `.like` for
   every row).
3. **The record** — `getSong`'s `playerOverlays…likeButtonRenderer.likeStatus`
   (`SongMetadataParser.parseLikeStatus`).
4. **`SongLikeStatusManager`'s cache**, written by settled ratings and by the sources above.

The bar's like button describes the video *the bar names*, and the bar lags an in-page track change
exactly like the title and byline it renders (ADR-0037). The observation was taken on `trackChanged`,
which fires while the bar is still painting the outgoing song — so the previous, liked song handed its
`LIKE` to the incoming, unrated one. And it could never be corrected, because `likeStatus: nil`
(unknown) and `.indifferent` (known, not rated) were treated as the same answer: `fetchSongMetadata`
applied a record only when it was `!= .indifferent`, so the record's "this video is not rated" was
dropped and the guess stood.

The selector was unscoped as well, so on a page carrying another like button (a playlist or album
header) the observer could read a surface that was never about the playing video.

## Decision

Each source now answers only questions it can actually answer, and the record is the authority:

- **The observation is anchored or dropped.** `updateLikeStatus` takes the video the player holds, the
  video the bar names, and whether the bar's text was too stale to be believed. It applies a status
  only when the bar names the track this service holds, the bar's text was trusted, and the status is
  this track's — never the one about to replace it. `INDIFFERENT` from the button stays untrusted: the
  attribute is absent until the bar renders it, and an absent attribute is not a removed rating.
- **The button is the bar's.** The observer queries the like button inside `ytmusic-player-bar`.
- **`.indifferent` is an answer.** `fetchSongMetadata` writes the record's status — including
  `.indifferent` — to `currentTrackLikeStatus` and to the cache. Only a record with no like button at
  all (parser `nil`) leaves the cache alone, so "unknown" still never overrides a known rating.
- **A user's rating outranks a record.** `next` responses are cached
  (`APICache.TTL.songMetadata`), so a record fetched after a click can still describe the state before
  it. `SongLikeStatusManager` therefore remembers the video IDs the user rated in this session
  (`hasUserRating(for:)`) and their cache value wins over a fetched record. A burst that rolls back
  clears the mark, because the server never took that rating.

## Consequences

### Easier

- A wrong `LIKE` can no longer outlive the moment that produced it: the record is asked for every track
  that reaches the player (`enrichSongMetadataIfNeeded`) and its `.indifferent` now clears the bar.
- No source can attach its rating to a neighbouring track: the observation carries its own video IDs.
- The rule is one sentence, not four call-site special cases: the record answers, unless the user
  answered more recently.

### Harder

- A correction costs a `getSong` for a track whose state is unknown; the per-video guard
  (`songMetadataRequestedVideoId`) and the API cache keep that to one request.
- The cache now stores `.indifferent` for videos whose record was seen. Surfaces that read the cache as
  "unknown when absent" (`AddToPlaylistPopoverButton`) already treat `.indifferent` as unknown, so their
  behaviour is unchanged.
- Session-scoped user marks are not persisted. A rating made in an earlier session is re-asserted by
  the next record, which is what persistence should do anyway: the server holds the rating.
