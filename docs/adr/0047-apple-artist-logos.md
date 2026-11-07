# ADR-0047: Artist Wordmark Logos from Apple Music

## Status

Accepted

## Context

An artist page currently identifies the act with a text name under an "Artist" eyebrow. Apple Music
and many artists' own branding use a **wordmark logo** instead — the band's signature drawn as type.
YouTube Music does not publish one: its artist header (`musicImmersiveHeaderRenderer`) carries a
banner and a square avatar, nothing more.

Apple Music's public, unauthenticated artist pages do carry one. Each page embeds a
`serialized-server-data` JSON blob for hydration, whose artist header holds an `artistLogo`
dictionary (a transparent PNG URL template plus its pixel size), and holds `null` for the many artists
without a wordmark. The Android client BitChord resolves it from nothing but the artist's name by
searching the iTunes API for the artist id and reading that page.

The risk is identity, not parsing: a name is not an identity (`Krsna` on Apple is not `KR$NA` on
YouTube), and the search returns whichever same-named artist it ranks first.

## Decision

Add `AppleArtistLogoService`, an `actor` with a per-process cache, and draw the logo in the artist
header where the name otherwise sits.

- **Two requests, plus evidence.** The iTunes search API (`entity=musicArtist`) yields candidates whose
  normalized names equal the page's. A candidate is only accepted when its iTunes album titles share a
  release title with the YouTube page's own albums, singles or songs — the page's own catalogue is the
  evidence that the two artists are the same act. Without titles, nothing is asked for. Candidates that
  fail the check are skipped rather than replacing the first match.
- **Parse defensively.** The URL template is filled at 1000 px wide (`{w}`/`{h}`/`{c}`/`{f}`), and the
  result must be `https`. Every surprise — a missing script, a `null` logo, a template without size
  placeholders — reads as "no logo", never as an error on the artist page.
- **Found wordmarks are cached; misses are not.** In memory for the session and on disk for a month
  (`ArtistLogoCache`, `~/Library/Caches/com.kaset.artistlogos`), keyed by the YouTube browse id rather
  than the name (two channels with one name deserve different answers). Nothing is stored for an artist
  without a logo, so one whose wordmark Apple adds later picks it up on the next visit. Entries age out on
  read, because artist art changes and a month-old answer is worth asking for again.
- **The artist's own colours, unless the logo has none.** A coloured signature is drawn as Apple
  delivers it. A single-colour wordmark (white, black, grey) is drawn `.renderingMode(.template)` in
  `.primary` instead, because white ink on a light header (or black ink on a dark one) is invisible; the
  tint follows the appearance. `ArtistLogoRendering.isMonochrome` decides by sampling the ink, and one
  coloured pixel is enough to keep the whole logo in colour.
- **Padded margins are cropped.** Apple pads its wordmarks differently from artist to artist, so drawing
  them in a fixed frame made some look half the size of others. The transparent margin is cropped to the
  ink, then the result is fitted into a box (320 × 64) where a wide wordmark takes the width and a square
  one the height. The artist's name shows until the image is ready and whenever no logo exists, and
  remains the accessible label; name and logo share one fixed-height slot so the swap crossfades without
  reflowing the header.
- **User control.** `SettingsManager.artistLogosEnabled` (default on) gates the lookup, exposed as
  "Artist Logos" in Settings → Artist Artwork, next to the other third-party artwork source.

The lookup runs in `.task(id: detail.id)` on the header, so leaving the page cancels it.

## Consequences

- Coverage is partial by design: logos exist for a minority of artists, and only for those whose Apple
  catalogue proves the match. Everyone else keeps the text name.
- The feature depends on Apple's page markup, which is not a published API. Parsing is guarded so a
  change degrades to "no logo"; it can never break the artist page.
- No credentials are involved: both the iTunes API and the artist page are public, so nothing has to be
  discovered at runtime (unlike the Apple Music canvas token in ADR-0013).
- The header gains one network lookup per artist visit (cached per process), and one more for the album
  check; both are skipped when the setting is off or the page has no catalogue titles.
