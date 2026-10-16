# ADR-0033: Playlist/Album Header Action Row (Play, Shuffle, and the Actions That Fit)

## Status

Accepted

## Context

The playlist and album detail page (`PlaylistDetailView`) draws its actions as a row of
`controlSize(.large)` buttons pinned to the artwork's bottom edge (ADR-0023). The row grew one button
per feature — Play, Shuffle, Play Next, Add to Queue, Add to Library, a playlist-management menu,
Refine — and every addition made the row wider for the same 180 pt artwork.

Two problems came with that:

- **The row no longer fits.** A row of five or more large buttons plus a pair of menus is wider than
  the header has room for on a normal window, and the layout can only clip: the header's height is
  definite (the 180 pt thumbnail plus its insets) and the row does not wrap.
- **Adding a feature kept costing the row.** Starting radio from a playlist meant another button, and
  the next feature would mean another. The row was the only place a page action could go.

Apple Music's own album and playlist pages answer both the same way: a prominent **Play** button, a
**Shuffle** button, and a single "…" overflow menu holding everything else. That bounded the row at
the cost of burying the secondary actions one click down, so the first version of this decision moved
*every* secondary action into the menu and left the row with three controls.

That trade was wrong for this page. Two of the actions it hid — Play Next and Add to Queue — are the
ones a listener reaches for while looking at a track list, and the row had room for them: with all
seven actions folded away, a normal window sat with a mostly empty action row while the menu carried
controls that fit beside Play. The complaint that settled it was exactly that: *the actions are not
in the row even when there is enough space.* A page action should be visible when there is room for it
and reachable when there is not, which is a responsive row rather than a fixed three-control one.

## Decision

`PlaylistDetailView`'s header row is **Play, Shuffle, every secondary action that fits, then one "…"
menu** — the menu the fixed version always had, now holding exactly what the row left out.

**The actions are declared once, as an option set.** `HeaderAction` (`.radio`, `.playNext`,
`.addToQueue`, `.library`, `.refine`) names the page actions a header can offer;
`availableHeaderActions(for:)` returns the ones this page really has (radio only when the header named
a mix, no refine and no playlist management for an album). The row and the menu then split that one
set: `headerActionRow(_:inline:)` renders the actions in `inline`, and `moreActionsMenu(_:inline:)`
renders `available.subtracting(inline)` — so an action appears exactly once, in the row when it fits
and in the menu when it does not, and no list of actions is written down twice.

**An action that cannot act is not offered, and the one it can act on is addressed properly.** The library
action — "Add to Library" / "Remove from Library" — is a `like/like` write whose target is a `playlistId`
(`YTMusicClient.subscribeToPlaylist`), so it only means something where the library can hold the page, and
only if it is sent the ID the library holds it under.

There are two ID shapes in play. A **playlist** is its own: `PL…`, with the `VL` browse alias stripped. An
**album** is not: its page ID (`MPREb_…`) is a page, and YouTube Music stores an album under its
`OLAK5uy_…` audio playlist — the ID its own listing uses, and the only one the write accepts. The album's
header names it: the album's radio target is `RDAMPL` + that audio playlist (`PlaylistParser` §
`parseRadioPlaylistId`, the same target the row's Star Radio action plays). `PlaylistDetail.libraryId`
reads it back off `mixPlaylistId`, and the page's membership — the control's label and the write itself —
is stated in that ID (`PlaylistDetailView.libraryPlaylist`) rather than in the page it was opened by.
Before any of this the action was offered unconditionally and sent the page's own ID: on an album page that
is a page ID the library can never list back, so the control read "Add to Library" whether or not the album
was saved and clicking it changed nothing.

Two pages are left with no library action at all, both of them things nothing stores: a generated mix or
radio (`RD…`: `RDCLAK…`, `RDEM…`, `RDTMAK…`, `RDAMVM…`), and Liked Music (`LM`), which *is* the library's
list of liked songs. An album whose header named no radio target has no audio playlist to derive and is
offered no action either, rather than one that writes a page ID nowhere. `Playlist.isLibraryHoldable(id:)`
is the same rule for surfaces that hold a bare item rather than a loaded page — the search results' playlist
context menu — and it can only judge the ID it is given. The row and the menu both come off
`availableHeaderActions`, so one gate covers both places.

The one page that keeps the action without being holdable is one the library *already* holds (see
`PlaylistDetailView.offersLibraryAction(for:)`): the control it draws is then "Remove from Library", which
is how the library offers to drop an item — including the radio playlists its own listing can carry.
Liked Music is refused before that check, so its page is never offered a control that would read as a way
to empty the library's liked songs.

**The row states its width in shapes, grades them, and draws the widest one that fits.** `shapeLadder`
lists the row widest-first — two shapes that *name* their secondary actions (four of them, then three),
then the same actions as glyphs (five, four, three, two, one, none). The row lays every shape out
invisibly at its own ideal width (`shapeMeasurers`: `fixedSize`, hidden, out of the accessibility
tree), reads each width back with `onGeometryChange`, and draws
`shapeLadder[fittingShapeIndex(for: widths:)]` — the first shape in the ladder that fits the width the
header offers it. The row fills up as the window widens and folds back into the menu as it narrows, and
it ends at the "…" menu in every shape, so the menu's position is stable while the row grows and shrinks
around it. No drawn shape overflows its width, and the choice itself is one pure function of measured
numbers; until a shape has been measured the row draws the narrowest one, which is the only shape that
cannot overflow a row it has not been measured against.

**The shape is the row's own state, and the swap between shapes is stated in one step.** The row is not a
`ViewThatFits`, which picks a shape by laying all of them out and keeps its choice to itself: it cannot
say what it picked, so the row cannot tell the menu which actions it left out, and every shape it holds
stays in the layout and the accessibility tree. Measuring makes the choice the row's own, and only the
shape on show is built for display.

It was animated at first — the choice written inside `withAnimation(AppAnimation.quick)` with a
leading-anchored scale-and-fade `.transition` on the actions that come and go — and that was wrong for
this row. A window being resized is dragged across the rungs continuously, so the animation did not
follow a click; it was re-triggered by the drag itself, and every resize became a moving picture of
buttons growing and shrinking under the pointer. Read at a glance the row seemed to squirm rather than to
have changed what it shows. Stated in one step the row still changes shape while the window is dragged;
it does it the moment a rung is crossed instead of drawing the way there.

Measuring also means the row's width is not the shape's width: the row is wrapped in
`frame(maxWidth: .infinity, alignment: .leading)`, so the frame takes what it is offered and a shape that
outgrows the row cannot widen the row it is being measured against.

The grade is what makes the row responsive in the range a window actually has. Measured offscreen, a
named secondary button costs 134 pt of row where the same action as a glyph costs 53: the named four
need 735 pt of row, the four glyphs 408 and five glyphs 465. Folded away from the app's narrowest
window — the header's action row is offered the page's width less the artwork column, about 650 pt
when no sidebar is open — every glyph shape fits, so a glyph-only ladder would sit at its widest shape
at every window width a user can set and never move. The named shapes are the rungs that move.
`HeaderActionRowTests` measures the rungs offscreen and holds what the choice relies on: every shape is
narrower than the one above it (the selection reads the ladder widest-first and stops at the first shape
that fits), the widest shape needs more than 700 pt of row and the narrowest less than 200, more than
half the shapes fit a 650 pt row, and `fittingShapeIndex` picks the widest shape that fits a width, falls
back to the narrowest when nothing has been measured, and never picks a shape wider than the row it is
given.

**Play is the only labelled control that is not a secondary action.** It stays the labelled
`.buttonStyle(.glassProminent)` capsule and the only accent-tinted control in the row; Shuffle is a
bare `shuffle` glyph. The secondary actions are `.buttonStyle(.glass)` at `.controlSize(.large)`,
named in the wider shapes and bare glyphs in the narrower ones — a glyph carries its action's name as
its tooltip and its accessibility label, so a narrower shape costs pixels, not meaning. Five named
buttons do not fit beside the artwork in any window; five glyphs do not fit in a narrow one.

**The More menu is drawn by the row, not by macOS.** A `Menu` cannot be given the row's look by a menu or
button style. Left alone it keeps macOS's own pull-down chrome over the row's glass — measured, a flat
pill 61.5 pt wide, with a chevron; under `.menuStyle(.button)` its indicator costs another 27.5 pt
(74.5 against 47 without) and the row's `.buttonStyle(.glass)` still does not reach the control. So the
control is plain — `.buttonStyle(.plain)`, `.menuIndicator(.hidden)`, no chrome of its own — and states
its size and its material itself: `.glassEffect(.regular.interactive(), in: .capsule)` on a label of
`overflowControlSize`, 46 × 26 pt, which is what the glyph controls beside it measure in the running app.
Its glyph is a bare `ellipsis` — no ring icon inside it.

The control's label then has to state that it is a hit target, because a plain-styled `Menu` has no chrome
to give it a body: hit-testing stayed with the ellipsis' own ink, and the 46 × 26 pt of glass around it was
drawn and dead — the capsule opened the menu only when the click landed on the three dots themselves.
Measured in the running app, that is exactly what accessibility reported too: the menu's frame was the
glyph's 12 × 2 pt while the button beside it reported its whole 46 × 26. `.contentShape(.rect)` inside the
label, after the frame, is what makes the whole capsule the button (`WindowToolbar`'s back control carries
the same fix for the same reason), and the control then reports its own 46 × 26 pt like its neighbours.

**Every control in the row is pinned to one height** (`actionRowControlHeight`, 28 pt).
`.controlSize(.large)` does not mean one height for glass controls on macOS 26: a labelled glass
button measures 28 pt while an icon-only one measures 26, so the row's glyph buttons sat 2 pt short of
the Play button beside them. The row fixes the four configurations it uses to the labelled height
instead of mixing the two; `HeaderActionRowTests` measures each of them against the constant and fails
if the source stops applying it.

The pin is a layout height, not the control's own. Measured in the running app, a glyph control still
draws a 26 pt capsule inside the row's 28 pt box, which is why the overflow control states 46 × 26 pt:
the control the row draws has to be the size of the controls it sits beside, not of the row.

**The row stays pinned to the artwork's bottom edge.** ADR-0023's `ZStack(alignment: .bottomLeading)`
is kept, and the row is not moved under the metadata line: the pin is what makes the buttons line up
with the artwork's trailing corner, and — with nothing in the header flexible — what keeps the
header's height definite. The alternative, Apple Music's single info column with the row directly
under the track count, was tried and rejected: on a short title it reads as a column that stops in the
middle of the header, with the artwork's lower half empty beside it.

The **track count and duration stay in the info column**, under the credits. Apple Music's headers read
type, title, artist, then that line, and it describes the metadata rather than the buttons, which is
where it used to sit. The error lines a playlist action can produce stay directly below the row, next
to the control that produced them.

**The playlist-management menu is merged into the More menu** — Rename Playlist (which opens the
`popover`) and Delete Playlist (which opens the `alert`), after a separator, and only on a playlist the reader
can write to (see §*Amendment: what the menu's management section is offered on*). Both
presentations hang off the header rather than off the menu that opens them: the row lays out and measures
every shape of the ladder at once (`shapeMeasurers`), so a presentation attached inside the row would be
built once per shape and every copy would answer the same binding.

## Amendment: what a library write is addressed to, and what the library says back

The action above was gated correctly and still did not work, so this section records what the write and the
membership behind it actually need.

**The page's own save action is the target.** The header's save/remove menu item carries the ID YouTube
Music itself writes, under a `likeEndpoint`'s `target.playlistId`. `PlaylistParser` reads it out of the
header renderers (the same shape-agnostic walk the radio target uses) into
`PlaylistDetail.libraryPlaylistId`, and `PlaylistDetail.libraryId` prefers it — the radio-derived
`OLAK5uy_…` and a playlist's own ID are the fallbacks, for a header that named no action. Only the header
is scanned: a related item further down the page carries a save action of its own, and its target would be
that item's. This is what the write is sent, and an album's page ID never is: `like/like` answers
`MPREb_…` with `HTTP 404 NOT_FOUND` — the failure ytmusicapi's issue #585 documents as "you are using a
browseId, not a playlistId" — which is how an album's control failed while looking like a no-op.

**Membership is asked with every ID the page can be known by.** The library lists a saved album by its page
(`MPREb_…`) — that is what its own listing navigates to — while the page is *saved* under its `OLAK5uy_…`
audio playlist, and the two are different strings. Asking with one of them reports an album the account owns
as unsaved, so `PlaylistDetail.libraryMatchIds` carries both and `LibraryViewModel.isInLibrary(anyOf:)`
matches on either (each against its `VL`-stripped form as well). The ID a *read* matches on and the ID a
*write* goes to are deliberately different questions: reads accept any spelling the library may store, and
writes only accept an ID the server accepts.

**The library listing carries albums, and it does not.** The landing page has no albums in it — they live
behind their own filter, the way followed artists do — so a library built only from the landing lost every
saved album, including one added a moment earlier: the page took the album locally, the refresh that
followed replaced that snapshot with a listing without it, and the same refresh put "Add to Library" back
on the page. That is the album that showed up and then vanished. `YTMusicClient.getLibraryContent()` now
fetches `FEmusic_liked_albums` alongside the landing and the artists corpus (a failure there is logged and
tolerated — a library without its albums is still a library), merges the two by normalized ID so an album
is never listed twice, and the library item walk accepts album browse IDs (`MPREb_…`/`OLAK5uy_…`) instead
of dropping them. `FEmusic_library_albums`, which this repository's endpoint list carried, answers
`HTTP 400`: the filter is `FEmusic_liked_albums`.

**The control follows the server.** `SongActionsHelper.addPlaylistToLibrary`/`removePlaylistFromLibrary`
report whether the write landed, and the header only flips its optimistic local state when it did —
otherwise it says so and stays where the server is. Flipping it whatever happened left the page claiming an
item was saved when the write had failed, and the next click then tried to remove something that had never
been added. A failed write also has to say *how* it failed: `SongActionsHelper.writeFailure` logs the error's
kind with its HTTP or URL code (`apiError(HTTP 404)`, `networkError(URLError -1009)`), and never the service's
message about the ID the write named — the log is read on a shared console, and logged as plain text that
whole description comes out as `<private>`, which is how a control that failed every time it was clicked left
no trace at all.

A page is offered the action when there is an ID a write could use — its own `libraryId`, or, for a page the
library already holds, the ID the library lists it under. An album page ID is refused as a stored ID too
(`Playlist.isAlbumPageId`), because removing through it fails the same way adding through it does.

**The More menu is drawn only when it holds something.** `HeaderAction` is the whole set the page offers, and
the menu holds what the row could not render — which on an album that fits *whole* is nothing: an album has
no playlist to rename or delete, so its management section is empty too. A `Menu` with no items still draws,
takes the click, and opens onto nothing, so the row states
`showsOverflowMenu(available:inline:showsManagement:)` and draws the control only when the answer is true. The
measurement passes go through the same row builder, so the shapes the row measures are the shapes it draws.

**Membership is read from the window's library, which has to be in the page's environment and has to be
loaded.** Both halves were wrong at once, and each is enough on its own to make the control lie:

- `LibraryViewModel` is read by the page through `@Environment`, and an optional read of a value nobody
  injected is `nil` — not an error. `MainWindow.detailView(for:)` now states the injection around *every*
  page of the content pane, which is where the branch that builds a playlist straight from the sidebar is;
  it used to sit on the navigation branches only, so a playlist opened from the sidebar had no library at
  all and answered "not in the library" to its own reader, in a window whose sidebar listed it.
- The snapshot was loaded on login and by the Library view alone. Every other way into a page — the sidebar,
  a search result, an artist's discography — asked membership of a library that had never been fetched, and
  the answer was "no". `LibraryViewModel.loadIfNeeded()` fills an empty snapshot in and leaves one in hand
  alone; `Sidebar` calls it once the session is signed in (it is the surface every window has, and it draws
  its own playlist list from the same snapshot), and a playlist/album page calls it beside its own load.

Both failures are silent: neither a missing injection nor an empty snapshot throws, and the read-back is a
`Bool` that means "no" for "unknown". The page therefore logs what it resolved — `Header decision: vm=…
listing=… matches=… inLibrary=… write=… management=… refine=… actions=… overflow=…` — so the console can tell a
wrong label apart from a stale library.

`overflow` is one flag per shape of the ladder, widest first, saying whether that shape of the row draws its
"…" menu. That is the whole of "the menu shows at some window widths and not others": it is drawn in the shapes
that leave an action over, and a shape that renders everything the page offers has nothing to put in a menu.
On the Liked Music page above it reads `00000111` — the menu is there for the three narrowest shapes, where the
queue actions no longer fit, and absent from the wide ones.

## Amendment: what the menu's management section is offered on

The More menu's Rename and Delete were gated on "this is not an album", and Liked Music is the page that
gate read wrong.

**Rename and Delete are offered only where the account can write them.** Both are owner-only writes —
`browse/edit_playlist` with `ACTION_SET_PLAYLIST_NAME`, and `playlist/delete` — and the header marker that says
the signed-in user owns a playlist (`musicEditablePlaylistDetailHeaderRenderer`) is the same one that gates
every other playlist write. `PlaylistDetail.supportsPlaylistManagement` is that rule, and it is what the menu's
management section and the row's gate both ask: Liked Music is refused by name as well as by the marker,
because it *is* the library's list of liked songs — the account can reorder it (`isSortable`) but can neither
rename nor delete it — and a mix (`RD…`) and an album are refused for the plain reason that there is no stored
playlist behind the page. The old gate put the two actions on Liked Music, and — because the page had nothing
else to put in a menu — they were the only items in the "…" it drew, at the window widths where the row had a
leftover action to justify one at all.

**The refine action is advertised only while it can run.** Its control hides itself when Apple Intelligence is
unavailable (`.requiresIntelligence()`). An action in `availableHeaderActions` with no control on screen is an
action the menu counts as left out of the row, which is how the Liked Music page came to draw a "…" for an item
that was not there; the set and the control now agree. On a machine whose model is unavailable, that page's
menu is gone entirely at the shapes that render everything it offers.

## Consequences

### Positive

- The row cannot outgrow the artwork. What does not fit is in the menu, so the clipping ADR-0023
  lists as a negative stops being reachable through feature growth — the row folds instead.
- The row earns its width: on a normal window the secondary actions a listener uses are visible, and
  a narrower window trades them for the menu instead of clipping them.
- Play and Shuffle — the two actions a listener actually clicks — keep their size and position.
- A new page action is one case in `HeaderAction` plus one branch in the row and the menu. The row
  re-flows on its own.
- "Remove from Library" is finally reachable: the old row could only *add*, because the button
  disappeared once the playlist was in the library. An album page reaches both through the audio playlist
  its header named, which is the ID its membership is read and written by.
- A saved album is in the library and stays there: the library lists it, the album's page reads that back
  whatever spelling the listing used, and the control's label and the write agree on one ID.

### Negative

- The number of visible actions depends on the window's width, so a screenshot of the header is not a
  stable description of it. The menu is the stable part; the row is not. The named shapes widen that
  gap: at 735 pt of row the secondary actions are named, at 650 pt they are glyphs, and below that
  they leave the row one at a time.
- The row lays out every shape of the ladder while it measures, so the header's action row is created
  once per shape per render pass. It is a handful of buttons and menus, and nothing in the row holds
  state or presents anything — but that is the constraint on what may be added to it.
- The row's own measurements arrive one layout pass after the header appears, and the row starts on its
  narrowest shape: the secondary actions appear on first display rather than being there from the first
  frame, and with the swap unanimated nothing covers that first step. It is one rung of one row, and it is
  the price of measuring the shapes in the first place.
- `.requiresIntelligence()` hides its subject (`EmptyView`) rather than dimming it, so the Refine
  control — in the row or in the menu — appears and disappears with availability. No separator is
  placed around it, so nothing is orphaned when it goes. The action is advertised only while it is
  available as well, so a row measured before the model is ready folds for a control that is not on
  screen and then folds again once it is.
- The menu's items come and go with the window's width, so two users on different window sizes see a
  different menu.
- Loading the library costs one more request (`FEmusic_liked_albums`), and saved albums now share the
  library grid with playlists rather than having a section of their own — the view has no album section,
  so an album sits among the playlists it was saved beside.
- A library write that fails is now visible (an error line under the row) instead of silently leaving the
  control where it was. That is the honest reading, and it also means a server-side failure can no longer
  be mistaken for a click that did not register.
- An album page whose actions all fit has no "…" at all, where it used to end in one that opened onto
  nothing. Consistent with the ladder — the row shows what it has room for — but it does mean the menu is
  not the one stable control in the row: on a wide window it may be absent entirely, and what it holds
  depends on the width as well. Liked Music reads the same way now that Rename and Delete are no longer
  offered on it: the menu is there for the shapes that cannot fit its queue actions, and gone from the
  shapes that can.
- Rename and Delete are unreachable on a playlist whose header carries no editable marker, even if the
  server would in fact accept the write: the marker is the only ownership signal the app has, and a read
  that is missing is not a write to make. The alternative — offering the pair everywhere and reporting the
  error after the click — is what put them on Liked Music in the first place.
- The library is fetched for every window that opens, signed in, before anything asks for it, rather than on
  the way into the Library. It is one browse (cached by `APICache.TTL.library`) and it is what the sidebar's
  own playlist list needs to be drawn at all — the list was empty until the Library page had been visited.

## Testing

UI tests address the row by identifier: `PlaylistDetail.playButton`, `.shuffleButton`, `.moreButton`,
the five secondary buttons (`.radioButton`, `.playNextButton`, `.addToQueueButton`, `.libraryButton`,
`.refineButton`) and `.metadata`, all mirrored in `TestAccessibilityID`.

`testHeaderActionRowSitsOnTheArtworkBottomEdge` covers the layout the row has to keep, and the two
things it got wrong: the row ends on the artwork's bottom edge, starts below the metadata line, stays
inside the window, and the More menu is the same size as the glass buttons beside it. It
also asserts the responsive property directly — at least one secondary action is drawn in the row
rather than only in the menu on the test window's width — and that no action's identifier resolves to
more than one element, which would mean a shape the row is not drawing is in the accessibility tree.
The shapes the row measures are `accessibilityHidden`, so they are not it.

The row's control sizes are unit-tested as well, because a UI test needs the app built and installed and
a control 2 pt short is not something a build can catch: `HeaderActionRowTests` hosts each of the row's
four control configurations and asserts they all come out the row's height, asserts the overflow control
comes out the size of the glyph control beside it, measures what macOS's own chrome would cost the menu
(the 61.5 pt pull-down pill, and the 27.5 pt chevron a button-style menu adds), measures the ladder's
rungs, exercises the selection, and guards the row's source — the shared height on all four controls, the
control's size constant, the plain style, the hidden indicator, the glass capsule, the label's own frame
and hit shape, that the swap carries no animation and no `ViewThatFits`, that the library action is gated
on a page the library can hold and on Liked Music being refused first, the actions split out of one option
set, and the shape list it is measured against. It also holds the empty menu: `showsOverflowMenu` is exercised
directly — an album that fits whole draws no menu, an action the row could not render keeps it, a page the
reader owns keeps it for its management actions, and Liked Music, which has neither, keeps it only for the
actions the row could not render — and the row's source is guarded to draw the control through that gate, to
ask for the management with `detail.supportsPlaylistManagement`, and to draw Rename and Delete inside that
same rule rather than on "this is not an album". `PlaylistLibraryActionTests` holds what the rule answers:
the reader's own playlist has management, and a playlist without the marker, Liked Music (marker or not), a
mix and an album do not. `PlaylistLibraryActionTests` guards the pane's own injection, which is
the half a test of the page cannot reach: `MainWindow.detailView(for:)` has to state `.environment(
self.libraryViewModel)` around every branch of the content pane, the sidebar's playlist branch included.
`LibraryViewModelTests` holds `loadIfNeeded` — it fetches for a window that has no snapshot, does not
re-fetch one already in hand, and is still able to retry after a failed load — and `SongActionsHelperTests`
holds that a failed write's summary carries the error's kind and code and not the service's message.
`PlaylistLibraryActionTests` holds the taxonomy itself:
a mix or radio (`RDCLAK…`, `RDEM…`, `RDTMAK…`, `RDAMVM…`) and Liked Music have no library ID at all,
while a playlist (`PL…`) and an album's `OLAK5uy_…` audio playlist do — and an album page derives that
playlist from its radio target (`RDAMPLOLAK5uy_…`, and no other `RDAMPL` target), which is the difference
between an album page that can be saved and one that must not offer the action. It also holds the amendment:
the page's own save target wins over the derived one and is refused when it is a page, a radio or a `VL`
alias; a page matches its library entry through either ID it can be known by; and a library entry matches
the page it was opened from. `LibraryViewModelTests` holds the matching itself, and `PlaylistParserTests`
holds that a saved album in a library listing (the landing's grid and shelf shapes, and the albums filter's)
comes back as an entry instead of being dropped.

Both the menu's size and its spacing are asserted in the running app as well: it reports the same 46 × 26
pt as the glyph button beside it, centred on the same line, and starts 10 pt after the control in front of
it — the row's own spacing, where the size and the hit shape its label states are what make the two hold.

## References

- [ADR-0023](0023-playlist-search-and-sort.md) — the header's layout, its definite height and the
  action row's alignment to the thumbnail.
- `Sources/Kaset/Views/PlaylistDetailView.swift` — `HeaderAction`, `headerActionRow(_:inline:)` and
  `moreActionsMenu(_:inline:)`.
- `Sources/Kaset/Models/Playlist.swift` — `PlaylistDetail.supportsPlaylistManagement`, `isEditable` and
  `isLikedMusic`.
- `Sources/Kaset/Views/QueueSidePanelView.swift` — `QueueFooterActions`, the same
  `ViewThatFits`-with-glyph-fallback shape for a row that has to survive a narrow container.
- `Sources/Kaset/Views/SharedViews/StartRadioContextMenu.swift` — the radio action the row starts.
