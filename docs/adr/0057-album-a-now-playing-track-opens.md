# ADR-0057: The Album a Now-Playing Track Opens

## Status

Accepted

## Context

The now-playing sidebar's title opens the playing track's album, and the song menus' *Go to Album*
opens the same page. Both read `Song.album`, which comes from YouTube Music's own byline: the album
run on the track's page.

YouTube Music treats a release that exists only as a single as that single's album. Playing "Flowers"
reports `Flowers` as the album, and the page it opens holds one song — the same song that is playing.
A user who asks for the album therefore gets a single posing as an album. The real release,
`Endless Summer Vacation`, is not named anywhere on that page or in the track's metadata: its listing
names a different video ID for the same song (the album's audio item, not the single's), so nothing in
the track's own record links the two.

The album has to be discovered and then proved. Discovery and verification both have traps:

- An album-filtered search for the **artist alone** ranks a discography by popularity. For
  "Miley Cyrus" the real album is the fourth row, behind `Plastic Hearts`, a 2026 release, and
  `Bangerz`, and the single is eighth. A bounded number of album-page reads never reaches it.
- An album-filtered search for the **track on the artist** (`Miley Cyrus Flowers`) leads with
  `Endless Summer Vacation`, then other albums and covers. Search rows carry the album's page ID,
  title and a subtitle (`Album • Miley Cyrus • 2023`), but no parsed artists and no year.
- A page proves the album only by its track list. Reading an album page is a `browse`, not a
  playlist page: it must not write the open playlist page's continuation state, or a background
  lookup would hand the playlist on screen another list's pagination.

## Decision

Resolve the album when the reported album is the track's own single, and only then:

- `TrackAlbumResolver.needsResolution(albumTitle:trackTitle:)` — the reported album's title equals the
  track's, allowing a `- Single` / `- EP` suffix. This is the trigger for every lookup, so a track that
  reports a real album (the common case) costs nothing.
- `TrackAlbumResolver.resolve(...)` — searches albums for `"<artist> <track>"`, keeps navigable
  candidates that are not credited to another artist (an uncredited row is unknown, not foreign), and
  reads at most `maxAlbumLookups` (5) album pages. A page wins when its listing holds the song's title
  — compared case-, accent- and spacing-insensitively — among **more than one** song, so the single
  cannot be re-selected, and when its credits, if it exposes any, name one of the track's artists.
  Nothing is returned when no page proves the song.
- `YTMusicClient.getAlbumPage(albumId:)` reads that page (title, credits, tracks) without touching
  `playlistContinuationToken` or `playlistRecommendationsToken`.

`PlayerService.resolveAlbumIfNeeded(videoId:)` runs after the structured record lands in
`fetchSongMetadata`, at most once per video, in a background `Task`. It replaces `currentTrack.album`
with the proven album (and the queue row's album, so the row's menus agree), leaving the report alone
when nothing proves a better one. A wrong album is worse than the one YouTube Music named.

## Consequences

- The sidebar title and *Go to Album* open the real album for tracks YouTube Music reports as singles,
  which is the visible complaint this fixes.
- The lookup costs one search and one to five album-page browses, once per played track, and only for
  tracks whose reported album is their own title. Album pages are cached under the playlist TTL, so
  replays within the TTL cost nothing.
- Album pages expose no artist byline in the parsed model (the header has no `MUSIC_PAGE_TYPE_ARTIST`
  runs; the artist sits in `straplineTextOne`, which is not parsed), so the artist check is a no-op on
  live album pages and the track list plus the ranked query carry the proof. Parsing that strapline
  would strengthen the check without changing the flow.
- A track whose reported album genuinely *is* an album named after its title track (an album called
  `Flowers` holding the song `Flowers`) is searched too; it survives because the page lists the song
  among more than one song, which is exactly the proof a single fails.
- Collaboration and covers albums are handled by the credits the search rows do expose and by the
  page's own credits when it has them; a covers album reached before the real one is rejected only by
  its credits, so the ranked query is what keeps it behind the real album.
- Album resolution does not feed the canvas lookup: the canvas is keyed by `videoId` and resolved from
  YouTube's reported album, and the Apple Music provider already discovers the album from Apple's song
  record (ADR-0013). A canvas that arrives before the album is resolved does not need to be redone.
