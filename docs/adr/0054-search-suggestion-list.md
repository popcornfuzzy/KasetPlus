# ADR-0054: The Suggestion List Is Part of the Search Field

## Status

Accepted

## Context

The search page drew its autocomplete list inside the page's own `VStack`: the field and the list sat
in a `ZStack`, the list was pushed down by a hard-coded `padding(.top, 44)`, and the stack grew by the
list's height. Four things followed:

- The list did not look like part of the field. It pushed the divider and the results down instead of
  floating over them, and its width and edges were unrelated to the field above it.
- Clicking an entry filled the field but did not appear to search. It did start a search — behind a
  panel that came straight back: the view watched `query` and refetched suggestions from `onChange`,
  so the panel reopened over the loading state it had just triggered. `showSuggestions` also required
  `results.isEmpty`, which tied the panel to the results rather than to the field.
- The state lived in three places: `SearchViewModel.suggestions`, the view's `selectedSuggestionIndex`
  and a `showSuggestions` computed property that guessed from unrelated state.
- The field and the list were two separate Liquid Glass shapes, one a capsule and one a rounded panel.
  Two glass surfaces never read as one control, and the glass added a second visual language to a page
  whose content is flat.

The search itself also waited on a 300 ms debounce meant for typing, although the only callers were
explicit actions (Return, a chosen suggestion, a filter change).

## Decision

- **The view model owns the list.** `query`'s `didSet` schedules the debounced fetch, keeps the
  results a refinement is reading, and reopens a list that was dismissed. `isSuggestionsVisible`,
  `suggestionRows`, `dismissSuggestions()` and `accept(query:)` are its whole interface; the view no
  longer repeats a step in `onChange`.
- **One search path.** `accept(query:)` puts the text in the field, closes the list and runs the
  search immediately. Clicking a row, Return on a highlighted row, a recent search and a filter change
  all go through it, so they cannot diverge.
- **The typed query is the list's first row.** `suggestionRows` is the trimmed query followed by the
  provider's completions, deduplicated against it. Return always has something to run, the list reads
  as the field continuing, and a word the provider has no completion for still gets a clickable row.
- **One surface, and it is flat.** `SearchView.searchSurface` is a single rounded card: the field row
  at its top, a hairline, then the list (`SearchSuggestionList`) inside it. It is painted with
  `controlBackgroundColor`, a `primary` hairline and a 14 pt corner — no liquid glass. The card is a
  sibling of the page column in a top-aligned `ZStack`, and the column reserves only the field's
  height, so opening the list grows the card downward over the results instead of moving them.
- **One highlight for pointer and keys.** Hover sets the same index the arrow keys move; the
  highlighted row shows the Return glyph, and Tab completes the field with it without searching.
  Escape closes the list; with the list already closed it clears the field, as an `NSSearchField`
  does.
- **No search debounce.** Typing reaches the network only through the 180 ms suggestions fetch. A
  search is always an explicit action, so it starts at once.
- **A refinement keeps the results on screen.** Typing a new query no longer empties the page: the
  previous results stay, and stay clickable, until the response replaces them. `.loaded`, `.loading`
  and `.loadingMore` draw through one branch of the content switch so the list keeps its identity —
  and its scroll — while a search or a pagination runs. The field's leading slot swaps its magnifier
  for the search's progress, and the page-sized indicator is reserved for the first search of a
  session, which has no rows to hold on to.

## Consequences

- The list cannot reopen over the search it just ran: accepting a suggestion clears it, and dismissal
  is only lifted by the next edit.
- A search for a chosen suggestion is one round trip, not 300 ms plus a request.
- The card's own field row is the only geometry that places the list; there is no offset to keep in
  step. `SearchSuggestionList` draws rows only, so the click target and the row labels cannot
  disagree.
- The card has to be a sibling of the page, not an overlay of the bar. Measured offscreen: the same
  card drawn as an overlay of the bar's 40 pt placeholder had its *fill* clipped to the bar's bounds
  while its rows kept drawing over the results — a semi-transparent panel over the songs, which is
  the defect this structure exists to prevent. As a `ZStack` sibling the fill spans the whole card
  (154 pt of white for a four-row list, against 15 pt in the overlay layout).
- The previous rows stay on screen while the next ones arrive, so typing does not flash the list
  empty. The field carries no focus ring of its own: the open card is the cue that it is editing.
- The "Press Return to search" placeholder is only what an empty page says; it can no longer appear
  between two searches. Refining while offline keeps the rows as well, rather than replacing them
  with the connection error.
- The card opens and closes on a snappy spring: its height grows or collapses, revealing the list
  from under the field's hairline, and the shadow fades in with it. The list's rows fade as they are
  inserted, and the highlight crossfades between rows instead of jumping. Only the card's height
  animates, and it floats, so nothing below the field moves.
