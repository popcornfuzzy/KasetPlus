# ADR-0053: The Toolbar Row's Leading Slot (macOS 26 Placement)

## Status

Accepted. Restates two assumptions of [ADR-0030](0030-appkit-window-shell.md) and
[ADR-0034](0034-shell-owned-window-title.md). Verified on macOS 27; **unverified on macOS 26** — see
"Consequences".

## Context

The bar was reported as correct on macOS 27 and wrong on macOS 26: "the title and the buttons are in the
wrong place". Nothing in the source is gated on either version, so the difference is AppKit's, and the
question was which of the bar's two assumptions about AppKit's layout is the one that changes.

The bar is the app's own `NSToolbar` ([ADR-0030](0030-appkit-window-shell.md)) whose page region is
bounded by the sidebar's tracking separator, with the back control and the page's name as its leading
items. That placement has never been the app's to state: AppKit draws the window's title as a view at the
**row's leading edge** and lays every item after it, so the app's part is to hide the title and let the
items take the slot ([ADR-0034](0034-shell-owned-window-title.md)).

Measured in a reproduction of this window — 1240pt, one `NSSplitViewController` with sidebar/page/inspector
items, the app's item order and install state, `toolbarStyle = .unified`, `fullSizeContentView`,
`titlebarAppearsTransparent`, `titlebarSeparatorStyle = .none`:

| Title | Title view in the row | `.toggleSidebar` | sidebar separator | back control | page name |
|---|---|---|---|---|---|
| hidden | none | 92 | 172 | 181 | 229 |
| visible | `NSToolbarTitleView` x=92 **w=160** | 252 | 296 | 305 | 353 |

(hidden, column open, measured on macOS 27.2.1)

So a title view present in the row moves **every** item — the sidebar toggle, both tracking separators,
the back control, the page's name and the right-hand run — right by its width, and the separators stop
sitting on the dividers they track. That is one failure that looks like several: a title in the wrong
place, controls shifted, and page controls drifting towards the Now Playing column.

Two further measurements, because both were candidate levers and neither works: an empty title string
still produces a 160pt title view, and `NSToolbar.centeredItemIdentifier` does not remove it. On macOS 27
the only thing that removes the view is `titleVisibility = .hidden`; there is no second lever.

That leaves the bar depending on two version-dependent facts:

1. **`titleVisibility = .hidden` removes the title view.** The app states it late: `MainWindow` and the
   shell write it while the window is already on screen, and `AppDelegate.installMainWindow` built the
   window with the default `.visible` and showed it. A version that materialises the title view when the
   window is displayed and does not drop it when the visibility is stated afterwards is exactly the
   reported symptom, and it is a state the app can avoid stating.
2. **The standard separator identifiers find the split view.** `.sidebarTrackingSeparator` and
   `.inspectorTrackingSeparator` "automatically configure themselves" from a split view AppKit discovers,
   and the app states its item list **before** the toolbar goes into the window, so discovery has to
   catch up. If a version lays the standard separators out as items in the row instead of binding them to
   the dividers, the page's region is bounded by a flow position instead of the divider — the same
   shifting controls, without a title view involved.

## Decision

**The bar states both facts itself, and publishes what AppKit actually laid out.**

- `AppDelegate.installMainWindow` states `window.titleVisibility = .hidden` **while the window is being
  built**, before it is ever shown, so no version is given a displayed window to build a title view for.
  The shell's re-assertions stay: `applyTitleVisibility()` still runs on every state apply and after every
  toolbar install, because a takeover or the fullscreen player's chrome can put a title back.
- `WindowToolbarController.trackedSplitView` is the shell's own split view, set in
  `WindowShellController.viewDidLoad`. The delegate answers `.sidebarTrackingSeparator` and
  `.inspectorTrackingSeparator` with `NSTrackingSeparatorToolbarItem(identifier:splitView:dividerIndex:)`
  — divider 0 and divider 1 — instead of returning `nil` and leaving
  alignment to discovery. A controller with no split view (tests, or a controller built before the shell)
  still returns `nil` and gets AppKit's standard items, so nothing depends on the order the two are built
  in.
- The item order (`WindowToolbarItems.identifiers`) is **unchanged**: it still states where each separator
  is, the two APIs agree on the geometry (measured identical at 1240pt with the column open and closed,
  and the explicit items are the ones actually laid out), and the order is what the item-list tests cover.
- **The row is read back once per install, and repaired if a title view is holding it.**
  `WindowShellController.checkTitleSlot` reads `ToolbarRowSnapshot` and, when the title is
  hidden and a title view is in the row, works the bar back into place. The reading is logged:
  `Toolbar row: titleView=<width|none> firstItemX=<x> titleVisibility=<hidden|visible>`. The classes
  (`NSToolbarTitleView`, `NSToolbarItemViewer`) are AppKit's and have no public API, which is why the app
  never derived layout from them; a single reading after install is not layout, it is the answer to
  "which assumption is the one that is wrong on this machine".

### The repair, and what it is allowed to do

Measured in a window whose title is **visible** on macOS 27 — the state a version that ignores the hidden
visibility leaves behind:

| statement | title view in the row | first item |
|---|---|---|
| (none) | 160pt | x=252 |
| `titleView.isHidden = true` | 160pt | x=252 |
| `titleView.removeFromSuperview()` | 160pt | x=252 |
| `window.titleVisibility = .hidden` | none | x=92 |

The view is **not** the lever: hiding it keeps the frame the row was laid out around, and AppKit
reinstates a removed one on the next layout. Only the visibility statement frees the row. The repair
therefore escalates two public-API steps, each followed by a reading of the row:

1. **Re-state the visibility** — `.visible` then `.hidden` in one turn, so the value really changes and the
   intermediate layout is never drawn.
2. **Re-install the toolbar** — `window.toolbar = nil`, `install(in:)`, `titleVisibility = .hidden`, so the
   row is built while the title is already hidden. This momentarily removes the toolbar, which costs the
   page its top inset for that turn; it happens once, only in the broken state.

Both steps are followed by `Toolbar row repaired: titleView=… firstItemX=…`, so the outcome on a 26
machine is a number, not a hope: `titleView=none firstItemX=92` means the bar is placed by the same rule
as on 27.

Neither step runs unless `hostedWindow(_:)` still answers: the shell's own view must still be in that
window, and the window must still hold the app's toolbar. The repair acts a turn after the install that
asked for it, and in that turn the shell can be handed to another window or the toolbar can be replaced —
acting then would strip the toolbar from a window the app no longer draws, or fight whatever replaced it.
`ToolbarTitleSlotRepairTests` drives the real shell for both refusals.

## Consequences

**Easier**

- The leading slot is stated before the thing that would fill it exists, which is the only ordering the
  app controls.
- Each tracking separator is told its split view and divider index when it is created. The region a page's
  controls are laid out in no longer depends on AppKit discovering the split view from the window after
  the item list was already stated.
- A report of "the buttons are in the wrong place" now arrives with a number: a title view in the row, or
  a first item that does not start at the window's leading edge, names the mechanism instead of the
  symptom.

**Harder / traded off**

- **The macOS 26 result is unverified.** No macOS 26 runtime was available: the machine this was fixed on
  runs macOS 27.2.1, and these statements measure identically to the previous ones there (the hidden-title
  row is unchanged, and the explicit separators lay out at the standard ones' positions). What is *proven*
  is that the app no longer depends on a title view materialised for a displayed window, nor on separator
  discovery; what remains is whether that is the whole of the 26 difference. The `Toolbar row:` line is
  the check: on macOS 26 it either reports `titleView=none firstItemX=92` — the bar is placed by the same
  rule as on 27 — or it names the assumption that still does not hold.
- `WindowToolbarGeometryTests` now asserts the two placements directly: the back control and page name
  lead the page's region (`backControlLeadsThePageRegion`), and a hidden title leaves no title view in the
  row (`hiddenTitleLeavesNoTitleViewInTheRow`). Both are AppKit's state, measured in a real window; on a
  version that fails them, the failure is the diagnosis.
- The row walk is one traversal per toolbar install, not per layout pass, and it reads frames only — no
  layout is forced. The repair mutates nothing but the window's own state, and only when the row is
  already wrong.
- The measurement that justifies the repair is a test with teeth: `hiddenTitleMovesThePageNameBack` shows
  the name at its leading position, then pushed by more than 100pt with a title view in the row, then back
  at the leading position once the title is stated hidden. `titleViewIsFound` covers the finder the repair
  gates on.
