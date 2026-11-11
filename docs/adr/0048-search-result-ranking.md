# ADR-0048: Search Results Follow YouTube Music's Order

## Status

Accepted

## Context

YouTube Music already ranks a search response: the "Top result" card comes first, then each result
shelf in turn — the order its own UI draws. The app was not using it. `SearchResponse` flattened the
parsed rows into four arrays, and the "All" list rebuilt them as every song, then every album, then
every artist, then every playlist. Two failures followed:

- For a song query the "Top result" card is the track's official music video, and the album version
  was the first shelf row — so the list led with the video and showed the album version second.
- Artists were always appended last, so an artist query pushed the artist page below every song, even
  when YouTube Music's own top result was that artist.

None of that order came from YouTube Music; it came from the flattening.

## Decision

- `SearchResponse` keeps the API's own order in `orderedItems`, which `allItems` now returns. The
  parser appends each row as it walks the sections, so the card stays first and the shelves keep their
  sequence. Responses built in code default to grouping by kind.
- `SearchResultRanker` no longer reorders by kind and no longer promotes artists. Its only job is to
  collapse a song and its music video into the album version, at the pair's first position: a flat row
  list would otherwise show the same track twice, where YouTube Music draws the card as a large hero.
  A row without artist names — the top-result card — is matched on title alone.
- The card's `Song` keeps its `musicVideoType`, read from the title run's watch endpoint, so the
  collapse recognises a music video.

## Consequences

- The list order is YouTube Music's, including the position of the top-result card.
- A song search leads with the album version; the card's video row is folded into it in place.
- An artist search leads with the artist page through the card, with no name-matching heuristic of
  our own.
- The card is drawn as the app's own quiet tile rather than a second visual language: the release
  card from an artist page — kind line, bold title, one supporting line, the circular play control
  under it — with YouTube Music's related rows beneath a hairline, three across. A fixed side column
  left a dead middle at window widths, so the related rows share the width instead.
- The row the card would have been is dropped from the list, so the track it shows is not drawn twice.
- The card carries the item's quick actions at its trailing edge, centered on the head, the pair its own
  page leads with and labeled the way that page labels them: Play and Shuffle for an album or a playlist;
  Shuffle and Mix for an artist. Each fetches the page that holds the tracks (or the mix's playlist ID)
  before it queues anything. The chevron stays beside the title, where it reads as "this opens" rather
  than as one more action; a song has none, and a podcast show — whose actions live in the card — has no
  quick action of its own.
- A song's supporting line is rebuilt from the song rather than the card's text, so an album version
  standing in for the card's official video does not keep the word "Video". Other kinds keep
  YouTube Music's own line: it carries numbers a row has nowhere to put.
- `SearchTopResultCard` is the one place that layout lives; `SearchResultRanker.topResult(_:)`
  supplies it, and `SearchResultRanker.ranked(_:)` leaves the hero's row out.
