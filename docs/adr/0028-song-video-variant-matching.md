# ADR-0028: Song/Video Variant Matching

## Status

Accepted

## Context

A track on YouTube Music often exists twice: as an audio "song" (`MUSIC_VIDEO_TYPE_ATV`) and as
the official music video (`MUSIC_VIDEO_TYPE_OMV`). Playlists, radio mixes and YouTube autoplay
routinely put the video variant in the queue. The video variant disrupts listening:

- the now-playing artwork becomes the video still instead of the album cover;
- the audio is the video's mix/master, which can differ from the song release;
- the queue and history show a different track than the user thinks they are playing.

Kaset is an audio player that shows music in a small PiP-style miniplayer. The goal is for the
song version to play **everywhere** (queue, direct play, radio/mix, session restore) with its
album art, while the video stays available for the miniplayer when the user asks for it.

## Decision

Play the **audio (song) variant** wherever a track has one, and remember the paired video as the
entry's *counterpart*. Surface the video only through the miniplayer.

### Where the pairing comes from

The `next` and `music/get_queue` responses wrap a paired track as a
`playlistPanelVideoWrapperRenderer`:

```
playlistPanelVideoWrapperRenderer
  primaryRenderer.playlistPanelVideoRenderer        -> the entry that plays
  counterpart[0].counterpartRenderer.playlistPanelVideoRenderer -> the other variant
```

This is the data behind YouTube Music's own song/video switcher. The counterpart carries its own
`videoId`, title, byline, thumbnail and `musicVideoType`. Parsing it is deterministic — no title
heuristics. `PlaylistPanelItemParser` extracts both sides, and `RadioQueueParser`,
`PlaylistParser` and `SongMetadataParser` attach the counterpart and the `musicVideoType`.

In practice the public API does not always include the counterpart (verified with
`swift run api-explorer variants <videoId>`): a radio of music videos came back with no
counterparts, and the per-track `next` response did not include one either. So a second source is
needed.

### Backfill by filtered search

For a video entry with no counterpart, `SongVariantMatcher` searches the filtered song catalogue
(`searchSongs`, which excludes videos) with the title plus primary artist, then scores candidates
on normalized title, artist overlap and duration. A title-equal, artist-equal, length-equal match
is accepted; a same-title/different-artist result (a cover) is rejected. Results are cached by
video id, and lookups that found nothing are remembered so a track is not retried on every pass.

Resolution happens **ahead of playback**, for the next `variantResolutionWindow` (4) queue
entries, so a video is swapped for its song before it starts. `play(song:)` also resolves the row
that is about to play, and replaces that row in the queue, before it chooses a page: the track
starts exactly once, on the version that should play. If a lookup is already in flight for another
entry the starting row keeps its video for this play; it is still the same track, and the next
track is prepared normally. Entries that arrive already paired cost no extra request.

A row that carries only an id has no type to read. That is the case for a track played from a
`music.youtube.com/watch?...` link: `AppDelegate` hands `play(song:)` the `"Loading..."`
placeholder, which used to look like an ordinary song to the check above, so a linked music video
played as a video even when its song version existed. `play(song:)` now asks for that track's
record (`getSong`) before choosing a page when the row is a bare placeholder, then resolves it
like any other video. The record is the request `fetchSongMetadata` makes after the load and the
response is cached, so this moves that fetch ahead of the page choice rather than adding one.

Verified against `1x1wjGKHjBI` ("Tongue Tied"): `swift run api-explorer variants` reports
`MUSIC_VIDEO_TYPE_OMV` with no counterpart, while the filtered song search for "Tongue Tied
GROUPLOVE" returns the ATV `UCcGuJzewCo` as its first result.

### Model

`Song` cannot recursively store a `Song`, so the pairing is a flat `SongCounterpart`
(`videoId`, title, artists, duration, thumbnail, `musicVideoType`). `Song.counterpart` holds the
*other* variant. `SongVariantMatcher.audioPreferred(_:)` returns the entry to play, carrying the
video as its counterpart when one was chosen.

### Playback and the miniplayer

- Every queue entry point (`playQueue`, `playWithRadio`, `playWithMix`, radio application,
  infinite-mix continuations, insert/append, tuner chips, session restore) runs songs through the
  matcher, and `play(song:)`/`play(videoId:)` always load the audio variant.
- A list row is the playing row when either side of the pairing is `currentTrack`.
  `PlayerService.isPlaybackTrack(videoId:)` folds the row's id through
  `canonicalPlaybackVideoId`; `PlaylistDetailView` asks it instead of comparing ids, so a
  YouTube-generated playlist that lists the music video keeps its playing indicator after the
  entry is swapped to the song.
- A known video counterpart makes `currentTrackHasVideo` true, so the miniplayer's existing
  `prefersVideo` path clicks YouTube's "Video" tab when the miniplayer is expanded. The page then
  reports the video's id; `canonicalPlaybackVideoId(for:)` folds that observation back onto the
  song entry so `PlayerService+WebQueueSync` does not treat the switch as queue drift and does not
  replace the album art with the video still.
- `SettingsManager.preferAudioVersionsEnabled` (General → "Prefer Audio (Song) Versions", default
  on) gates the whole behavior. When off, Kaset plays whatever the API returns, as before.

### The sidebar video switches the stream

Showing the video is a playback decision, not a presentation one: the video is a different upload
from the song. `PlayerService.setSidebarVideoEnabled(_:)` therefore loads the video variant's page,
and disabling it loads the song's again, both from the position that was playing
(`PendingPlaybackVariantSeek`, applied by `SingletonPlayerWebView.seekWhenReady(to:resumesPlayback:)`
after the page loads). The queue entry and `currentTrack` stay the song, so the album art, the
like/library state and the queue row do not change; `canonicalPlaybackVideoId(for:)` folds the video
page's id back onto the song so the switch is not read as queue drift.

A video entry that is already playing when its song is found is **not** moved onto the song. Doing
that meant loading a second page in the middle of the song: the restart that was heard as a stutter,
and one the page could answer by playing something else. The queue row and the now-playing metadata
are updated to the song (so its album art is shown), the page finishes the upload it started, and
the next track begins on its song version from the first note. Only the reader's explicit
Video/Artwork toggle reloads a stream.

The page's own Song/Video tab is not the switch either: it is a control of the page, it chooses the
stream behind the app's back, and when the tab could not be found the surface stayed black. The
sidebar keeps the video surface mounted while the artwork is on screen (the host must not change),
but that hidden surface asks the page for the Video tab only while the video is actually shown. It
used to ask on the song page too, which moved the page back onto the video just after the switch to
artwork had loaded the song.

## Consequences

- Matched tracks show the song's album art in the bar, queue and fullscreen views; the video is
  one miniplayer toggle away.
- The queue and history now reference the song's video id. Like/library state is fetched for that
  id; a rating made against the video variant does not follow automatically.
- Backfilling costs one filtered search per unmatched video entry, bounded by the resolution
  window and the per-id cache. Playlists that are already songs cost nothing.
- A video with no song counterpart is left untouched, and a region-blocked song variant falls back
  to the video (logged, not silent).
- The counterpart is persisted with the queue (`SongCounterpart` is `Codable`); sessions saved
  before this feature simply decode without one.

## Alternatives considered

- **Counterpart only.** Rejected: the public API frequently omits it, which would leave the very
  tracks this feature targets unmatched.
- **Title/artist heuristics only (no counterpart).** Rejected as the primary source: less precise
  than the switcher data, which is exact when present.
- **Rewrite browse/search list thumbnails too.** Out of scope: matching is applied at playback,
  not to every browse shelf.
