# ADR-0038: Pinned Media Session Actions (and No Native Now Playing Claim)

## Status

Accepted

## Context

macOS routes media keys and the Now Playing panel's transport buttons to the app's active Now Playing
client. For Kaset that client is the shared `WKWebView`'s media session — the panel's rich card (artwork,
album, ±15s or track buttons) comes from there, and it keeps coming from there while the window is
closed, because `AppDelegate.windowShouldClose` only orders the window out so audio survives.

With the window closed, Next/Previous did nothing. The buttons reached the page's media session, and
Kaset's `nexttrack`/`previoustrack` handlers there were re-applied from a `requestAnimationFrame` loop
(`mediaControlOverrideScript`). WebKit stops producing frames for a page whose only window is gone, so the
loop went stale in exactly the state background playback leaves the app in: the next time YouTube Music
registered its own handlers, the system's Next advanced YouTube's player instead of Kaset's queue.

Two attempts that are **not** the fix, recorded so they are not repeated:

- **Claiming the Now Playing slot through `MPNowPlayingInfoCenter`** while no window is on screen
  (upstream Kaset's approach for a different symptom — media keys reaching Apple Music while paused).
  It fixed routing and broke the panel: macOS listed **two rows for Kaset**, WebKit's card with artwork
  and the claim's minimal one, because the two publishers are separate Now Playing clients rather than
  one card with two writers. Upstream's claim survives because WebKit's card withdraws in their setup;
  here it does not, so a claim is always a second row.
- **Re-applying the page's handlers on video events and a `MutationObserver`.** That is a second
  mechanism to keep in step with WebKit's throttling, and it fires too late to beat the page's own
  registration.
- **Publishing a MediaPlayer entry from an AppKit window transition.** Doing that inside
  `windowShouldClose` (with `MPMediaItemArtwork`) crashed the app in libdispatch — `Block was expected to
  execute on queue [com.apple.main-thread]` — while the system's now-playing machinery ran.

## Decision

The routing is fixed where the page registers it: `mediaControlOverrideScript` is injected at document
start (before YouTube Music's scripts, as the metadata pin already is) and wraps
`MediaSession.prototype.setActionHandler`.

- With the Next/Previous style on, any registration of `nexttrack`/`previoustrack` is replaced with
  Kaset's forwarders (`REMOTE_NEXT`/`REMOTE_PREVIOUS` → `PlayerService.nextFromRemoteControl()`), and
  `seekforward`/`seekbackward` are dropped so only track buttons appear.
- With the ±15s style, the same slot belongs to the seek actions; page registrations of
  `nexttrack`/`previoustrack` are dropped instead.
- `window.__kasetRefreshMediaControlStyle` re-applies the wanted style when the setting changes, and
  `DOMContentLoaded`/`load` give a document whose session was not ready at document start one more chance.
  Nothing runs on a frame loop, so a hidden page cannot make this stale.

Kaset publishes no Now Playing entry of its own. The pinned metadata (`nowPlayingMetadataScript`) keeps
the card describing `currentTrack`, and the pinned actions keep its buttons on Kaset's queue, so one
publisher and one row is all the panel ever has.

## Consequences

**Easier**

- Next/Previous reach `PlayerService` with no window on screen, which is what makes skipping work while
  the app plays in the background — through the same pinned handlers in every window state.
- Three mechanisms are gone: a 60 fps script on every playing page, the video-event listener set that
  re-applied it, and the document-wide `MutationObserver`. There is nothing left to keep in step with
  WebKit's frame production.
- One Now Playing row in every state.

**Harder**

- The pin owns four media-session actions, so both Now Playing styles are described in one place instead
  of split between the override script and the style-sync script.
- If a future symptom is "media keys go to Apple Music while paused", it cannot be fixed by claiming the
  slot — that is the two-row panel. The page's own session has to stay the only publisher.
- A page that replaces `navigator.mediaSession` outright needs the wrapper re-installed; `applyStyle()`
  does that, and the pinned getter/wrapper is idempotent when it runs again.
