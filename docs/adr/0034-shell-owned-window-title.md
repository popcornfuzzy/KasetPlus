# ADR-0034: Shell-Owned Window Title (No `navigationTitle` in the Shell)

## Status

Accepted

## Context

The window shell ([ADR-0030](0030-appkit-window-shell.md)) owns the window's toolbar as an
`NSToolbar`, but the pages inside it still stated `.navigationTitle` — toolbar-managed content.
SwiftUI's window controller answered every one by installing its own one-item toolbar on each push
into (and pop out of) a page, and back out again to nothing:

- opening an album or a playlist replaced the window's toolbar with SwiftUI's single back-item
  toolbar, and coming back out took the toolbar away entirely (`window.toolbar = nil`);
- the shell re-took its toolbar a runloop turn later, so the reader saw the titlebar's controls
  vanish for a beat — or not come back at all when no layout pass followed;
- while the replacement stood, the window's own title held the page region's leading slot, so the
  app's back control laid out after it — "the back button is with the other controls on the right";
- the pushed page's name lived in that title, so it flashed briefly and vanished once the shell
  hid the title for the back control;
- every toolbar swap recreated the hosted page-controls view mid-load, restarting the refresh
  button's `repeatForever` spin — the control juddered through every refresh.

The takeover observer (`observeToolbarTakeover`) kept repairing this, but repairing a fight each
navigation is not the same as ending it. ADR-0030 already named the durable fix: the pages should
stop asking SwiftUI for toolbar-managed content, with the window title stated by the shell instead.

## Decision

**No view hosted in the window shell states `.navigationTitle`. The pages publish their title to a
window-owned `PageTitleModel`, and the shell writes it to `window.title` itself.**

- `PageTitleModel` mirrors `PageToolbarModel`: `publish(id:title:)` on appearance (and when a
  detail's title arrives with its header), keyed `retract(id:)` on disappearance. Both registers
  are stacks, not slots: a navigation stack's root stays mounted while a destination is pushed over
  it, so the root never retracts — when the destination is popped and retracts, the window falls back
  to the root's entry underneath instead of keeping the popped page's title and controls. The title
  modifier is `.pageTitle(id:title:)` (`WindowPageToolbar.swift`).
- `WindowShell` takes the published title as `windowTitle` and the controller writes it to the
  window, only when it changed. Visibility is untouched: the title still yields the page region's
  leading slot to the back control (`applyTitleVisibility`, before the toolbar's items swap).
- The back control is back to a plain bordered chevron, and the page's *current* name is a hosted
  plain-text item beside it (`WindowToolbarItem.pageTitle`, broken out of the chevron's glass
  capsule by a fixed space). The window's own title stays hidden in every state — including across
  the fullscreen player's exit, which used to restore it visible and strand the back control on the
  right until the window was reopened. There is no visible title state left for a stale one to stick
  in, and the name the reader sees is always the page they are on.
- The refresh control spins through an indeterminate `ProgressView` rather than a restarted
  `repeatForever` rotation, the playlist toolbar reserves the sort menu's slot before the detail
  loads, and the toolbar controller only re-renders a hosted view when what it draws changed — so
  idle window updates no longer restart toolbar animations mid-load.
- `.navigationTitle` remains only where SwiftUI still owns the window: the Settings scene's views.
  The fullscreen player's chrome handling (`MainWindow.updateWindowTitleVisibility`) is untouched;
  it manages visibility, never the title string.

## Consequences

**Easier**

- Push/pop no longer replaces the window's toolbar object, so the takeover observer is defence
  rather than a per-navigation repair: no empty-titlebar flash, no back control on the wrong side.
- The back control always names where it goes, at the region's leading edge, in every loading state.
- Toolbar animations survive window updates; the refresh spinner cannot judder.

**Harder / accepted trade-offs**

- Each page states its title twice in spirit: once for the window (`pageTitle`) and once in its own
  header content. The two already agreed (the header is where the title came from); the window's
  copy follows the header through the modifier's `onChange`.
- The back label one level deep is the stack's root title, passed by the caller. Stacks deeper than
  one name nothing rather than risk naming the wrong page.
- SwiftUI previews and snapshot tests cannot cover the shell; as before, this is verified by running
  the app (`PageTitleModelTests`, `WindowShellTitleTests` and the toolbar-order tests cover the
  models and the item list, not the window).
