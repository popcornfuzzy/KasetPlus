# ADR-0032: Sidebar Video Replaces the Mini Player

- Status: Accepted
- Date: 2026-10-17

## Context

The player bar's PiP button toggled a floating mini player (in-window layer or detached
panel) for both music videos and podcast episodes. It duplicated what the fullscreen
experiences already do, added a second window-ownership model for the single WebView, and
auto-opened for every podcast whether or not an episode had video.

## Decision

- Remove the player-bar PiP button, the floating in-window mini player, the detached mini
  player panel (and its Window-menu command and Settings toggle), and the podcast
  auto-open / hidden-song fallback policies.
- The Now Playing right sidebar owns video instead: a toggle over the media area switches
  between artwork and the music video / video podcast. It only renders while
  `hasVideoSurface` is true, so tracks without video are artwork, full stop.
- The preference (`PlayerService.isSidebarVideoEnabled`) is sticky across tracks: a track
  without video falls back to artwork via `isSidebarVideoShowing`, and the next track with
  one shows video again.
- The sidebar video re-parents the same singleton WebView with the existing video-focused
  DOM presentation (`isExpanded: true, prefersVideo: true`). The main window keeps a hidden
  1×1 audio layer and stands down while the sidebar (or the fullscreen podcast slot) hosts
  the surface, so there is still exactly one host at a time.
- Height follows the observed video aspect ratio clamped to 0.75–2.4 (a vertical 9:16 video
  lands on the floor instead of becoming a tower), bounded to the artwork's 150–520pt
  range and the column's leftover height.

## Consequences

- One fewer window, one fewer ownership handover, no auto-opening surfaces: podcasts play
  audio-only unless the reader enables video in the sidebar (or fullscreen).
- Readers who used the detached panel lose the always-on-top companion window; the
  fullscreen experiences remain for watching while the app is backgrounded.
- `PlayerSurfaceHost`, `MiniPlayerPanelLayout`/`Placement`, and the mini-player Settings
  keys are gone; `SidebarVideoAspect` holds the ratio arithmetic with unit tests.
- Supersedes the mini-player parts of ADR-0031 (surface ownership) and ADR-0028 (the PiP
  counterpart wording); the variant-matching itself is unchanged.
