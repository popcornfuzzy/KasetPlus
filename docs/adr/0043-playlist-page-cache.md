# ADR-0043: A Stored Page per Playlist, Shown Before the Network Answers

## Status

Accepted

## Context

Opening a playlist started with a spinner and nothing else. The page has to ask YouTube Music for its
header and first page of rows, so every open paid a full round trip before the reader saw the playlist
they had been looking at a minute earlier — even when the app had fetched the same page in the previous
session. The list is the page: there is no useful partial state to draw while the request is out.

`APICache` did not cover this. It holds browse responses in memory with a TTL, so it answers only inside
one session and only while the TTL has not expired, and its disk mirror is used *only offline* — serving it
online would present a changed feed as current. A playlist page is different from a feed: it is a named
list the reader chose, and showing yesterday's copy of it for a moment while today's loads is exactly what
was asked for.

The artwork had the same problem from the other side. `ImageCache` keeps thumbnail bytes on disk, so the
image would appear without a request — but only if the page knows the URL, and the URL lived in the API
response that was not stored anywhere.

## Decision

`PlaylistDetailCache` stores one page per **account and playlist** under
`~/Library/Application Support/Kaset/PlaylistCache`, as a versioned envelope around `PlaylistDetail`
(bumped `schemaVersion`, the playlist and account IDs repeated inside the file, plus `savedAt`). It is
injected into `PlaylistDetailViewModel` (default `.shared`; tests pass a temporary directory) and is a
value-type, `Sendable` store so reads and writes happen where they always did: around the fetch.

`PlaylistDetailViewModel.load()` now:

1. loads the stored page for the account the page is loading for and installs it as `.loaded` — header,
   credited artists, track count, duration, rows, and the artwork **URL**, which is what the header and
   the accent background draw from and what `ImageCache` already has bytes for on disk;
2. fetches the first page as before, replacing the stored copy when it arrives;
3. stores the fetched page (`install(_:)`), so every successful open — including a pull-to-refresh and a
   sort-order change — leaves the copy the next open starts from.

The account is part of the cache key rather than a filter applied afterwards: a playlist is the account's
own copy, so one account's rows must never open under another (`loadIfAccountChanged` seeds the incoming
account's copy). The playlist ID is filed by its normalized spelling, because YouTube Music wraps an ID
in `VL` on some surfaces and serves it bare on others — Liked Music is `LM` in the sidebar and `VLLM` in
a browse response — and both name the same list.

A stored copy is a *display* of a page, not a paging session:

- It carries no continuation and no recommendation-section tokens, so `hasMore` is false until the fresh
  page lands. A continuation request issued before the first page would consume a token this session does
  not have and end paging for the playlist.
- A failed or cancelled refresh **keeps** the stored copy on screen instead of replacing a readable
  playlist with an error page. Only a page with nothing stored shows the loading state or an error.
- The stored page is dropped by `forgetStoredCopy()` when the playlist is deleted.

Entries older than 30 days are discarded on read, and the cache keeps the 120 most recently opened pages
(least recently opened first). `PlaylistDetail` and `PlaylistRecommendations` became `Codable` for this;
`Song`, `Artist`, `Album` and `Playlist` already were.

## Consequences

### Easier

- A playlist opens on its own content, artwork included, with no request on the critical path; the fresh
  copy swaps in behind the page rather than in front of it.
- Offline, a playlist that has been opened before remains readable instead of showing an error.
- The artwork needs no second cache: the stored URL resolves against `ImageCache`'s existing disk copy.

### Harder

- A playlist page has two sources of truth for as long as the refresh takes. Everything the fresh page
  says replaces the stored one wholesale (rows, header, sort order, paging), so the window is short and
  the rule is simple: the network wins.
- The page is rewritten each time it grows — after the first page, after every appended page, and after
  the recommendation section — so a playlist opens as deep as it was left. The writes are small (the
  rows the reader had loaded, not the whole playlist) and happen where the pages already arrive.
- A cached page can outlive a change made elsewhere (another client renaming, adding or deleting a
  playlist). The 30-day age and the refresh-on-open bound it, and the deleted-playlist path removes the
  entry outright.
