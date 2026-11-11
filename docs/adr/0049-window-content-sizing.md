# ADR-0049: The Window and Its Panes Never Size Themselves from Content

## Status

Accepted

## Context

The main window is an `NSWindow` whose content is an `NSHostingController`, and the three-pane shell is an
`NSSplitViewController` whose panes are three more `NSHostingController`s (ADR-0030). A hosting controller
publishes size constraints by default: its minimum, intrinsic and maximum sizes are measured from the SwiftUI
content it hosts. AppKit reads them whenever the window's content-size extrema are recomputed, and measuring
the hosted tree runs the page's own layout — including `LazyStack` placement for every realized row.

That measurement is not a size the app uses. The window's minimum is stated by the app
(`window.contentMinSize`, initially 900×600, kept in step with the open panes by
`WindowShellController.applyWindowMinimumSize()`), and each pane's width is the split view item's
(`minimumThickness` / `maximumThickness` plus the autosaved divider).

On the reported podcast show page, opening the page measured the page and the sidebar and left the main thread
inside `NSHostingView.minSize` for a 17.87 s hang (2026-11-11 20:24:02, Kaset 0.9.1 (25)). The crash report's
heaviest stack is exactly this walk — `NSHostingView.minSize` → `_sizeThatFits` → `_ZStackLayout` →
`LazyStack.place` → `ForEachState.forEachItem` — with a second branch in the same hosting view's layout.

## Decision

- The window's root hosting controller is created with `sizingOptions = []` in `AppDelegate.installMainWindow`.
- `WindowShellController.makePaneController()` creates the three pane hosting controllers with
  `sizingOptions = []` as well.

The window and its panes keep their geometry from the app and AppKit; neither asks SwiftUI for a size. No other
hosting controller in the app is affected.

## Consequences

- Opening the reported show page no longer starts the content-measurement pass. On that page a one-second sample
  before the change contained 33 `LazyStack` placement samples and 3 `NSHostingView.minSize` samples; after it,
  both are zero. The heavier playlist renderer reproduced the same walk at 36 of 53 samples before the change.
- The window still opens at its stated frame and minimum, and the panes keep the widths the split view gives
  them: the shell's own log after the change reports `split=1267 window=1267 sidebar=144 inspector=270`.
- A pane's content can no longer influence its size. A future pane that genuinely needs an intrinsic size must
  state it in the pane (or its split item), not rely on the hosting controller. Sheets, popovers and other
  hosting controllers keep their default sizing and are unaffected.
- The rule applies to any new window-level or pane-level `NSHostingController`: start it with
  `sizingOptions = []` unless the window is explicitly sized by its content.
