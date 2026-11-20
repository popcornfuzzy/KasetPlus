# ADR-0055: The Page Push/Pop Slide (and the Bar That Left the Pages)

## Status

Accepted. Verified on macOS 27 (the app's own window, driven through a real push and pop — see
"Verification"). Adds to [ADR-0030](0030-appkit-window-shell.md) and
[ADR-0046](0046-home-native-shelf-feed.md).

## Context

The app's page navigation swapped in place: pushing into an artist or an album, and pressing back, showed
the new page with no motion. The request was the motion the system apps have — the page sliding to the side
on a push and back the other way on a pop.

**SwiftUI cannot state it on macOS.** The SDK's `NavigationTransition` has exactly one concrete style
available here — `.automatic` — and both `.zoom(sourceID:in:)` and `.crossFade` are annotated
`@available(macOS, unavailable)` (checked in the macOS 27 SDK's `SwiftUI.swiftinterface`, not inferred).
There is no navigation transition to choose, so the motion is not a modifier away.

The system's own apps use AppKit's push transition: a `CATransition` of type `.push` on the container that
holds the page. That is what this app does, and it decides three things the app has to get right — which
layer receives it, which way it goes, and when it must not run at all.

## Decision

**`PageNavigationStack` slides the page's own layer, from the path's depth.**

- **The layer.** A `PageSlideProbe` — an `NSViewRepresentable` that draws nothing — sits in the page's
  hierarchy; once it is in a window it reports the nearest `NSHostingView` ancestor to
  `PageSlideTransition`. The shell hosts each pane in its own hosting view, so that is the content pane:
  measured in the running app at `w=767` in a 1267pt window, against the window's own 1267. The sidebar and
  the Now Playing column are separate hosting views and are untouched.
- **The direction.** The one place every page change passes through is `path.count`, which already drove
  the window's back control. A deeper path is a push (`.fromRight`: the new page enters from the trailing
  edge, the old one leaves towards the leading edge) and a shallower one is a pop (`.fromLeft`). A change
  at the same depth adds nothing.
- **Reduce Motion.** Nothing is added while `AccessibilityMotion.shared.reduceMotion` is on: the page
  swaps with no motion, which is what that setting asks for.
- **The swap underneath.** The app's own mutations — the toolbar's back control and the Now Playing
  column's credit routes, which are `PageNavigationModel.goBack()` / `open(_:)` — run in a transaction with
  `disablesAnimations` set, so the stack does not also animate the swap a layer transition is already
  moving. A `NavigationLink`'s push is SwiftUI's own action and is not wrapped; on macOS there is no
  transition for it to perform, so what the reader sees there is the layer's slide alone.

**The player bar moved out of the pages: it is the content pane's.**

The bar was drawn by every page, inside that page's stack. The first build of the slide therefore slid the
bar too — reported at once: "it works but the playerbar is in the animation which it should not be". A
`CATransition` moves the layer it is added to, and the bar was inside the host's page drawing; no mask,
sub-layer animation or offset can pin a part of a layer during a push, because the transition is composited
from the layer as a whole.

So the bar left the pages:

- `PagePaneController` is the content item's view controller: the page's hosting view fills it, and the
  bar's hosting view is a **sibling** pinned to the bottom in a band of `PlayerBar.bandHeight`
  (52pt capsule + 12pt under it = 64). The page is drawn behind that band, so its own background — an
  artist page's accent gradient included — is still what the bar's glass sits on, and the bar is not in the
  page's layer, so the slide cannot reach it.
- Every page keeps a `.safeAreaInset(edge: .bottom)` where the bar used to be, now reserving the band with
  `PlayerBar.reservedBand`. That is one statement per page instead of one bar per page, and it keeps the
  inset *inside* the stack: a pushed page reserves its own band, which is the arrangement
  [ADR-0030](0030-appkit-window-shell.md)'s two-bar measurement was about.
- The bar is a new SwiftUI root, so it inherits none of the window's environment. `MainWindow` states the
  four objects it reads (`PlayerService`, `WebKitManager`, `LibraryViewModel`, `CastService`) where it
  builds the bar.
- The pages no longer hide the bar on an error page. The bar is the pane's, so it stays where it was — which
  is also what the bar is for: the transport is still there while a page fails.

## Consequences

- Push and pop slide, and the bar — one bar, for the whole content pane — does not move. Verified in the
  app's own window: mid-slide frames show the page split into the outgoing page on the left and the
  incoming one on the right, with the bar unbroken across the bottom in the same place in every frame.
- **The verification needs a slow transition and a frame capture.** The real slide is 0.25s, and a window
  capture at ~6 frames a second lands about once per slide. The run that proved the layout used a
  temporary 1.2s duration (and a temporary driver, since Accessibility cannot drive the app), then both
  were removed; the shipped duration is 0.25s.
- **The motion only starts once the pane's content changes.** The transition is added in
  `onChange(of: path.count)`, before the new page is drawn and committed in the same turn. A future change
  that defers the page's content to a later display pass would show the transition over unchanged content.
- **`Page slide:` is a permanent diagnostic** (`docs/debugging.md`): it names the direction, the depths and
  the layer the transition was added to, so "the slide did not happen" is a line to read rather than a
  guess. No layer found means the pane's hosting view was not where the probe looked, and the line says so.
- **The bar's `@State` now lives for the pane**, not for a page: hovering the track to summon the seek bar
  survives a push, where before the bar was rebuilt with the page. That is the behaviour Music has.
- **The window has one bar to reason about.** The "two bars stacked" failure mode the per-page arrangement
  existed to avoid cannot recur: there is no per-page bar left to duplicate.

## Verification

- `swift test --filter PageSlideTransitionTests`: the transition's type, subtype and duration, the layer it
  is added to, same-depth and Reduce-Motion suppression, and a real `PageNavigationStack` push/pop driven
  through `PageNavigationModel` asserted on the hosting view's own layer (`CATransition` is filed under
  Core Animation's key `transition`, not the key it was added with — measured).
- `swift test --filter ContentPaneBarTests`: the bar's hosting view is in the pane beside the page, not a
  descendant of it, and its frame is the reserved band.
- The running app: `Page slide: push depth=0->1 host=NSHostingView<AnyView> w=767 layer=yes`, then the
  same for the pop, with mid-transition captures of the window.
