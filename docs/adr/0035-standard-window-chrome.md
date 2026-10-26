# ADR-0035: System-Owned Window Chrome

## Status

Accepted. Supersedes the chrome parts of [ADR-0030](0030-appkit-window-shell.md).

## Context

[ADR-0030](0030-appkit-window-shell.md) made the toolbar the app's so the two tracking separators could
bound the page's items by the sidebars. Along with it, the window was made non-standard: a clear sheet
(`isOpaque = false`), a transparent titlebar, full-size content, and the panes running to the window's top
edge so the navigation sidebar's `.behindWindow` material could blur the desktop.

That produced a band the app had to draw. Several attempts were made — a SwiftUI gradient over the page's
top, an opaque titlebar per split-view region, an AppKit band view — and each read as a hard-edged
rectangle over the content. Removing them left the page's own flat background as the only thing in the
band: a rectangle with no bar.

The window was then made a completely standard opaque one (titled, no full-size content, no transparent
titlebar) to get a real bar back. That fixed the missing bar but broke the layout the design depends on:
the navigation sidebar could no longer be full height, and the Now Playing column's artwork started below
the toolbar instead of at the window's top edge. It also made the bar permanently visible, where the system
apps the design follows show the toolbar's background only over content that scrolls beneath it.

The missing distinction was **transparency of the window versus transparency of the titlebar**. The app
had tried a transparent window; it had not tried an ordinary opaque window with a transparent titlebar.

## Decision

**The window is opaque; the titlebar is transparent; the system owns the bar.**

- `AppDelegate.installMainWindow` creates a plain `NSWindow` with
  `[.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]`, opaque, with
  `titlebarAppearsTransparent = true`, `toolbarStyle = .unified` and `titlebarSeparatorStyle = .none`.
- `WindowShellController.applyWindowChrome` re-asserts that configuration from the layout pass, so a
  later takeover cannot remove the style mask the full-height panes depend on, make the titlebar opaque,
  or put an experimental band back.
- The sidebar and inspector split items state `allowsFullHeightLayout = true`: their surfaces — the
  navigation sidebar's material and the Now Playing column's artwork — reach the window's top edge and the
  toolbar floats over them. The panes' own content is still inset by AppKit's safe area, so rows and page
  content begin below the bar.
- The toolbar's item platters and the scroll-edge effect are AppKit's. The **bar's own surface is the
  app's** (`WindowBarBackdrop`): AppKit draws the toolbar's items in windowed mode but no surface behind
  them, so the app puts an `NSVisualEffectView` above the content and below the titlebar. The material is
  **`.titlebar`**, the material of a real titlebar, not `.headerView` (a
  table-header material that tints a window-backed page by only a few levels: measured `#232423` over a
  `#1e1e1e` page, versus `#383938` for `.titlebar` — a surface that existed and looked absent). It blurs
  what scrolls beneath it and ends on a **hard edge**: a fade at the bottom read as a gradient wash laid
  over the page rather than as chrome.
- The surface spans **the page column only** (`WindowBarBackdropView.band(pane:themeFrameHeight:)`). The
  navigation sidebar and the Now Playing column run to the window's top edge and carry surfaces of their
  own — the sidebar's material, the column's artwork — so a band across the whole window painted over the
  very thing the full-height panes exist to show. The band is laid over the page pane's rectangle and
  follows it through divider drags, the column opening and window resizes (`NSView.frameDidChangeNotification`
  on the pane). The pointer is read **inside that rectangle**, so hovering a sidebar's top does not raise
  the page's bar.
- It is shown (`WindowBarBackdropPolicy`) while the page has **content under the band** or the pointer is in
  the band, and only while the window's toolbar is visible: the fullscreen Now Playing view hides the
  toolbar, and the bar goes with it — and comes back with it over a page that is still scrolled. That
  visibility is observed (KVO), not read on the next layout pass, because hiding the toolbar moves nothing
  the shell lays out and the surface otherwise stayed over the player until the pointer passed over it.
  Entering real fullscreen stays AppKit's. What holds it up is the page's **scroll position**, not the
  scroll gesture: the controller follows the page's own scroll view (the outermost,
  tallest one in the column) through `NSView.boundsDidChangeNotification` on its clip view, so a scroll that
  ends, the pointer leaving the window or another app becoming active does not uncover content still under
  the bar, and a page scrolled back to its top puts it away without waiting for a timer. Deriving it from the
  gesture instead — a flag set by a scroll event and cleared by a timer or a pointer move — was wrong twice
  over: the bar stayed up over a page scrolled back to its top, and it dropped off a still-scrolled page the
  moment the pointer left the window.
- The band is also **the page's titlebar for dragging**. AppKit's titlebar drag is a titlebar-view
  behaviour, and over the sidebars AppKit's own item views accept it; over the page the press landed on
  whichever SwiftUI view happened to be under the pointer, so dragging the page's top edge worked only
  sometimes. The band takes the press and **tracks the drag itself** (`mouseDown` / `mouseDragged` /
  `mouseUp`: the window's origin at the press plus the pointer's screen delta), rather than handing it to
  the window server with `NSWindow.performDrag(with:)` — that hand-off was tried, the strip reported the
  press, and the window stayed put. It also runs the standard double-click action
  (`AppleActionOnDoubleClick`) and the window menu, with scrolling forwarded to the view beneath it. The
  band is inserted **below** the titlebar so the toolbar's items keep their clicks.
- The app-owned `NSToolbar` and its tracking separators stay (see ADR-0030): the item list is still the
  app's, but it now lives in a system toolbar under a transparent titlebar.
- The standard titlebar keeps its own drag: nothing intercepts presses there. The app's drag lives only in
  the page's strip, which AppKit has no titlebar for. `KasetWindow` and `WindowDrag` and their tests are
  deleted.

## Consequences

**Easier**

- A bar exists with the behaviour the system apps show: its surface is absent over a page at its top,
  appears as soon as content scrolls beneath it or the pointer reaches the page's top edge, and stays up
  for as long as that content is there. Its span, its edge and its trigger are a small policy plus one
  view, covered by tests.
- The page's top edge drags the window as reliably as the titlebar does — the strip is chrome, so the
  press can no longer fall through to whatever the page happened to draw there. The drag is the app's
  pointer tracking rather than the window server's, so window-server-only conveniences (space switching
  during the drag, tiling hints) do not apply to this one strip.
- The navigation sidebar and the Now Playing column are full height, so the sidebar material and the
  artwork reach the window's top edge, as they did before the standard-window detour.
- Full-size content plus a transparent titlebar is the configuration Apple documents for AppKit's
  floating toolbar and scroll-edge effect; there is no custom chrome left to keep in step with the
  design.

**Harder / traded off**

- The window cannot blur the desktop through the sidebar: it is opaque, so the `.sidebar` material
  composites against the window's own background. Blurring the desktop would require a transparent
  window, which is exactly what made every material and band composite against nothing.
- Pages continue to paint their own surfaces; those surfaces now run under the transparent titlebar
  instead of starting below a solid one.
