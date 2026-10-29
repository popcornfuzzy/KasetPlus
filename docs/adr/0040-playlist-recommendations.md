# ADR-0040: A Playlist's Recommendations Are Not Its Tracks

## Status

Accepted

## Context

YouTube Music appends a suggestion shelf to the page of a playlist the signed-in account owns. The
shelf is a `musicShelfRenderer` section with its own title (for example "Recommendations") whose rows
are songs YouTube Music proposes adding to the playlist. It sits after the playlist's own
`musicPlaylistShelfRenderer`, and on pages that do not inline it the page's section-level
continuation loads it instead.

`PlaylistParser` collected every song row on the page into one flat list. Both shelves are
`musicResponsiveListItemRenderer`s, so the suggestions were numbered as playlist entries, counted in
the page's song count, played as part of "Play All", and offered "Remove from Playlist" — a write
against a playlist that never contained them. It looked like the playlist had extra songs at its end.

## Decision

A `PlaylistDetail` carries its recommendations in their own field:
`PlaylistDetail.recommendations` (`PlaylistRecommendations`, a title and its songs). `tracks` holds
only the playlist's own shelf.

- **Classification is positional, not textual.** The page's first shelf is the playlist: its
  `musicPlaylistShelfRenderer`, or — for older and album pages — its first `musicShelfRenderer`. Every
  song shelf after it is a recommendation shelf. The section's title is localized by YouTube Music
  (`hl` in the request), so it is displayed as served rather than used to identify the section.
- **Continuations are separated at the same point.** The playlist shelf's token paginates `tracks`.
  The recommendation shelf's own token — or, when the page does not inline the shelf, the
  section-level token — is returned as `PlaylistTracksResponse.recommendationsToken` and paginated by
  `getPlaylistRecommendationsContinuation()`. `PlaylistDetailViewModel` fetches it once the last track
  page has loaded and never appends its rows to `tracks`.
- **The page draws them as a section, not as entries.** `PlaylistDetailView` renders a titled section
  below the tracks whose rows keep the position's width but show no number, so they line up with the
  playlist and playing one does not shift the row. A suggestion's trailing control is one add button
  (`addSongToPlaylist`) that writes `ACTION_ADD_VIDEO` for this playlist and reloads it; it has no
  actions menu and no removal action.

## Consequences

- The reported song count, search results, "Play All" and row removal all describe the playlist alone.
- A recommendation section that only arrives through a continuation now needs one extra request after
  the track pages; pages that inline the shelf need none.
- The heuristics depend on the playlist shelf coming first. `PlaylistParserTests` pins an owned page
  with both shelves, the shelf's own token, and a titled continuation section, so a change in the
  response shape fails a test rather than silently folding suggestions back into the list.
