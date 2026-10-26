# Playback System

This document details the WebView-based playback system, its architecture, and implementation notes.

## Overview

YouTube Music uses DRM (Widevine) to protect Premium content. Native playback via AVPlayer is not possible because:

1. **Bot Detection**: YouTube's APIs detect non-browser clients and block them
2. **DRM**: Premium content requires Widevine CDM, only available in WebKit
3. **User Interaction**: YouTube requires a user gesture to start playback

Our solution: A **singleton WebView** that loads YouTube Music watch pages and plays audio through WebKit's native DRM support.

## Architecture

### Components

| Component | File | Purpose |
|-----------|------|---------|
| `SingletonPlayerWebView` | `MiniPlayerWebView.swift` | Manages the one-and-only WebView |
| `PersistentPlayerView` | `MiniPlayerViews.swift` | SwiftUI wrapper for the WebView |
| `PlayerWebViewPreload` | `PlayerWebViewLoading.swift` | When the layer is hosted and the shell loaded |
| `PlayerBarLoadingWash` | `PlayerBarLoadingWash.swift` | The wash in the bar's capsule while it waits |
| `PlayerService` | `PlayerService.swift` | Playback state and control |
| `PlayerService+WebQueueSync` | `PlayerService+WebQueueSync.swift` | Keeps native queue state authoritative when WebView events drift |
| `SingletonPlayerWebView+PagePlayback` | `SingletonPlayerWebView+PagePlayback.swift` | Starts a track inside the open document instead of navigating |
| `PlayerService+PagePlayback` | `PlayerService+PagePlayback.swift` | Proves the page really started that track, and falls back when it did not |
| `AppDelegate` | `AppDelegate.swift` | Window lifecycle for background audio |

### Singleton Pattern

```swift
@MainActor
final class SingletonPlayerWebView {
    static let shared = SingletonPlayerWebView()

    private(set) var webView: WKWebView?
    var currentVideoId: String?

    func getWebView(webKitManager:, playerService:) -> WKWebView
    func loadVideo(videoId: String)
}
```

**Why Singleton?**
- Prevents multiple audio streams
- Survives SwiftUI view recreation
- Survives window close/reopen
- Single source of truth for playback

## Playback Flow

### 1. User Initiates Play

```swift
// In a view
playerService.play(videoId: "dQw4w9WgXcQ")
```

This sets:
- `pendingPlayVideoId` = video ID
- playback kind (podcast classification) for transport and fullscreen presentation.
  Nothing auto-opens: the sidebar video only shows when the reader enables it and a video
  is available (see [ADR-0032](adr/0032-sidebar-video-replaces-mini-player.md)).

### 2. WebView Loads

`MainWindow` hosts the player layer for the whole signed-in session, not only while a video is
pending, so the WebView exists — and is already showing the YouTube Music shell — before the first
play ([ADR-0027](adr/0027-player-webview-preload-and-loading-strip.md)):

```swift
if PlayerWebViewPreload.shouldHostPlayerWebView(
    isSignedIn: authService.state.isLoggedIn,
    hasPendingVideo: playerService.pendingPlayVideoId != nil
) {
    // Hidden 1x1 audio layer; the Now Playing sidebar hosts the surface when its video is on.
    PersistentPlayerView(videoId: playerService.pendingPlayVideoId, isExpanded: false, prefersVideo: false)
        .frame(width: 1, height: 1)
}
```

With nothing playing yet, the representable gives the empty WebView one of two pages:

- the **active track's watch page**, when a restored session has a song that has not been resumed.
  It is loaded with `kaset_preload=1` and, when the session has a position, YouTube's own `t`
  parameter, so the page is already in place and at the right position when play is pressed;
- the **shell** (`music.youtube.com`, also preload-flagged) when there is no track to be ready for.

Both are *held*: Kaset permits autoplay, so a page left to itself would start playing on its own. The
document-start gate (`SingletonPlayerWebView.preloadGateScript`) swallows the page's `play()` calls
until a control Kaset drives lifts the hold, the user clicks or types in the page, or the mini player
is revealed for the user to use.

While a page is `empty`, `shell` or `preloaded`, it may only report what
`PlayerWebViewPage.observation` (`PlayerWebViewObservation`) allows. The shell has no track and
reports nothing; a preloaded page is a player that was told it started when its autoplay was
swallowed, so it reports **only which track it is holding** — title, artist, artwork, video id — and
none of its playback state, ads, end-of-track or remote-control signals. Taking those would put a
track that is not playing into the app's state and would zero the progress a restored session is
showing, and would let a silent page drive the queue.

What a preloaded page does contribute goes to `PlayerService.reconcilePreloadedTrackMetadata` rather
than `updateTrackMetadata`: the artist byline is normalized, the complete observation is published to
`observedWebMetadata` (which is what the lyrics pipeline waits on), the playback kind is refined, and
the page's artwork is adopted when the held track has none. The queue stays the authority on what is
playing, on the order and on the rest of its row (album, duration, like state), and the
queue-divergence handlers are never fed from a page that is not playing.

Its title and artist are the exception: when the page reports a byline that is not equivalent to the
held row's — shelf rows carry the album and year as extra artist entries, so their display
("SXTN, Leben am Limit, 2017") never matches the player-bar byline ("SXTN") — those two strings are
taken from the page, because that is exactly what pressing play used to do and nothing did at rest. It
only happens when the page also reports the held track's video ID, so a shell, a half-rendered page or
an ad cannot rename the track.

Both waits are reported into `PlayerService` and drawn by the player bar's loading wash
(`PlayerBarLoadingRule`): the **bar's own capsule is the mask**, the wash sits under the controls, and it
is drawn in the bar's foreground colour rather than the brand accent — which is what keeps it legible on
the light bar. A page load deepens it from the left, from WebKit's own `estimatedProgress`; a wait with
nothing to measure is the pulse on its own. A page load that ends keeps pulsing for a fixed tail
(`PlayerBarLoadingLinger.tail`), because the launch preload can be over before the window has finished
appearing: without it the wash is a flash nobody sees.

### 3. Video Starts

`PersistentPlayerView` either:
- Creates new WebView (first play)
- Reuses existing WebView (subsequent plays)

```swift
func makeNSView(context: Context) -> NSView {
    let webView = SingletonPlayerWebView.shared.getWebView(...)

    // Load if different video
    if SingletonPlayerWebView.shared.currentVideoId != videoId {
        webView.load(URLRequest(url: watchURL))
    }

    return container
}
```

When playback transitions to `isPlaying`:
- Fallback-driven mini player reveals auto-dismiss and mark user interaction
- Podcast auto-open does not auto-dismiss (stays visible)
- User-toggled mini player visibility is preserved until toggled off

### 4. State Updates

The observer script continuously reports:
- Playback state (`isPlaying`, `progress`, `duration`)
- Track metadata (`title`, `artist`, `thumbnailUrl`)
- The observed `videoId`
- Whether the observer thinks the track changed
- Like status and lightweight video availability

Swift updates `PlayerService` from every `STATE_UPDATE`, then uses
`PlayerService+WebQueueSync` to decide whether the reported track matches
Kaset's queue or whether YouTube autoplay needs to be corrected.

### 5. Track-End Handling

Natural track completion is handled by a dedicated bridge event:

```javascript
bridge.postMessage({
    type: 'TRACK_ENDED',
    videoId: lastVideoId || currentVideoId()
});
```

Swift validates that the ended `videoId` still matches the expected queue song
before advancing. This prevents stale `ended` events from double-advancing the
queue after Kaset has already loaded the next track.

## Track Changing

When user plays a different track:

1. `pendingPlayVideoId` changes, and `progress` resets to 0 (the old position belonged to the old song)
2. SwiftUI calls `updateNSView` (not `makeNSView`)
3. `SingletonPlayerWebView.loadVideo(videoId:)` called
4. The page's own player is asked to start the track in the open document; only if it cannot is the
   watch page loaded (current audio paused, target volume prepared, new URL loaded)

```swift
func loadVideo(videoId: String) {
    guard videoId != currentVideoId else { return }

    // Update ID immediately to prevent duplicate loads
    currentVideoId = videoId

    // First ask the page's own player to start it (see “Changing track inside the page” below).
    // Falls back to `loadWatchPage(videoId:)` — pause, set the target volume, then load —
    // when the page cannot start the track itself.
}
```

### Changing track inside the page

The page already has a player in it, and it can start another track without reloading the document
(see [ADR-0037](adr/0037-in-page-track-changes.md)). Kaset asks it to start one track — never to hold
Kaset's queue:

| What Kaset asks for | How the page answers | Status |
|---------------------|----------------------|--------|
| The track that is already playing | `playVideo()` if it was paused | `already-playing` |
| A row the page's own queue holds | `playVideoAt(index)` | `played-at` |
| Anything else | `loadVideoById` | `loaded-video` |
| A page with no player API | nothing — Kaset loads the watch page | `no-player` |

Only the last case (and a player that throws) costs a document load, which is what every track change
used to cost. The page's queue, store and player bar are deliberately left alone: they describe the
page's own queue, and rewriting them is what made the bar show a song that was no longer playing.

A swap does not re-render the page instantly, so the player bar can still be naming the previous track
for a moment. The observer reports both the track the player holds (`videoId`) and the track the bar
itself names (`barVideoId`); metadata from a bar naming another track is ignored, so the queue row stays
on screen until the page catches up instead of the app recording the previous song's title, artist and
artwork for the new one.

Because a page's answer is a command accepted, not a track started, `PlayerService+PagePlayback`
checks about a second later which track the page's player actually holds. If it is not Kaset's track,
the page is asked once more; if it still is not, the watch page is loaded (`WebQueueSettleRules`). A
page that never starts the track at all is loaded by a 3 s watchdog.

### The page's own end-of-track advance

YouTube Music finishes its own advance after reporting `ended`, so a row Kaset starts in that gap can be
moved past a moment later — the song after the one that just ended, skipped. A start that follows a
track ending therefore opens a short window (`PlayerService.trackStartGrace`, 2.5 s): a report of another
track inside it, or a second `ended` for the row that just started, is the page's leftover advance and
not a queue move.

Inside the window Kaset puts its row back rather than following the page — the page is the player, so
returning only the bar would leave the audio somewhere else:

```swift
self.reassertCurrentRowInPage()   // playInPage(row) + keepQueueMetadata, then re-check
```

A start the user asked for — play, Next, a queue row — does not open the window, so a deliberate skip
right after a start is still followed. A track ending without the media having reached its end
(`progress` short of `duration`) is ignored: that is a load that kept the old position, not a finished
song.

### The row's text is corrected by the page

A row that came from a card is not a description of the track: a Home card's second line is the card's
whole subtitle — its content type, the separators, the artist, the year — and reading every run as an
artist produced a byline like `Song, Artist`. `ParsingHelpers.extractArtists(from:)` now takes the runs
that carry an artist link (or, when none does, the runs that are not separators or metadata), so the
row is right before it is ever played.

When a start Kaset asked for is confirmed — the player holds the requested video and the player bar
names that same video — a *complete* observation (title and byline) replaces the row's text through
`heldTrack(_:describedAs:by:thumbnailUrl:)`. The row keeps everything else it knows (album, duration,
artwork, like state, feedback tokens); only the two strings the bar renders change. That is what makes
the now-playing bar correct itself a moment after a session starts from a card. Half a bar (still
rendering, an empty byline) changes nothing, and a bar that names another track is not believed at all.

When the WebView reports a new `videoId`, Kaset treats that as authoritative
even if the DOM title/artist are still stale. This avoids a race where YouTube
switches tracks before the player bar text catches up.

### Reports of the track just left

A start does not silence the page's reporting for the track it is replacing. For a moment it still
sends that track — a poll that raced the swap, an update queued before it, the bar's last paint — and
believing one of those reports moved the queue pointer *back* a row and flashed the previous song's
title in the now-playing surfaces until the next report moved it forward again.

Every start therefore records where playback came from (`PlayerService.noteTrackStart(from:to:)`), and
`updateTrackMetadata` ignores an observation of a track left within `departedTrackWindow` (3 s). The
window is not a ban: once it passes, a page that really is on that row is followed. Starting a departed
track again (Previous, a queue row picked again) takes it off the list, so its own reports are believed
at once.

The **words** are checked as well as the id. Mid-swap the page can pair the new video's id with the
outgoing song's title, and by id alone that is indistinguishable from a genuine correction of the row —
which is what flashed the previous title in the Now Playing column after a skip. A report whose title
matches a departed track's (as Kaset displayed it, or as the page last described it) is therefore
ignored too. Text that matches the playing row's own title is never treated as stale: the row already
says it, so dropping it would only delay a row that is already right.

### Text has to be anchored to the track it describes

The Now Playing column and the player bar both render `currentTrack`, so they cannot disagree with
each other — when the column showed another song's title for a moment, `currentTrack` itself had been
rewritten. A trace of the real page showed who wrote it: 0.2 s after a natural advance the page
reported the **correct new video id with a two-tracks-old title**, taken from the bar's DOM, with no
bar link and nothing from the player API; its real words arrived 1.4 s after the start.

So in the first `startedTrackTextGrace` (2.5 s) after a start, a description that contradicts the row
is believed only when it is *anchored* to the playing video (`PlayerService.ignoresUnanchoredText`):
the words came from the player API's own record, or the player bar's link names that video. Anything
else is the page still painting its previous state. It is dropped whole — no display change, and no
`observedWebMetadata`, so the lyrics search never runs against another song's words. Once the start is
no longer recent the page's words may correct the row again, and a row that has no title or byline yet
is filled at once either way.

### Which text is believed

The observer reports whether the title and byline it sent came from the page's **player API**
(`metadataFromPlayer`) or from the player bar's DOM. The player API describes the video the player
actually holds, so after an in-page swap it is the freshest text on the page — while the bar can still
be rendering the outgoing song. A bar that names another track is therefore not evidence against
player-API text (`updateTrackMetadata(..., metadataFromPlayer:)`), and a start Kaset asked for can adopt
and publish it at once instead of waiting for the bar to catch up.

The API's text wins whenever it differs from the bar's, even when the bar's link already names the new
video: a link that has moved on is not proof that the text has, and trusting the text there left the
outgoing song's title on screen for good. What keeps that from flashing the *previous* song is the
departed-track rule above — its id *and* its words — not a guess about which source is fresher.

This matters beyond the now-playing bar: `PlayerService.observedWebMetadata` is the observation the
lyrics pipeline gates on ("only search once metadata is updated") and searches with. When the gate could
not be satisfied, the loader fell back to the *row's* text after ~10 s — and for a row built from a card
that text is the card's, which is how a provider could match, and cache, another song's lyrics under the
right video id.

The search is also keyed by the words it used, not only by video id
(`SyncedLyricsService.searchedTexts`): a result found with a card's or an earlier track's text is stale
by definition, so a refined title re-runs the search instead of serving the wrong lyrics forever.

`STATE_UPDATE`'s `progress` and `duration` come from the media element when it has them, because the
progress bar's DOM attributes lag a swap and would otherwise hand the lyrics search the previous
track's length — which is what the duration score uses to choose between versions of the same title.

## Background Audio

### Window Close Behavior

By default, closing a window destroys its view hierarchy, killing the WebView. We prevent this:

```swift
// AppDelegate.swift
extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)  // Hide instead of close
        return false          // Don't actually close
    }
}
```

### App Lifecycle

```swift
func applicationShouldTerminateAfterLastWindowClosed(_:) -> Bool {
    return false  // Keep app running when window hidden
}
```

### Reopening Window

```swift
func applicationShouldHandleReopen(_:, hasVisibleWindows:) -> Bool {
    if !hasVisibleWindows {
        for window in NSApplication.shared.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return true
        }
    }
    return true
}
```

### Flow Summary

| Action | Result |
|--------|--------|
| Close window (⌘W) | Window hides, audio continues |
| Click dock icon | Window reappears, same audio |
| Quit app (⌘Q) | App terminates, audio stops |

## JavaScript Bridge

### Observer Script

Injected into every watch page. The real script is more defensive than the
minimal version below:

```javascript
(function() {
    'use strict';
    const bridge = window.webkit.messageHandlers.singletonPlayer;
    let lastTitle = '';
    let lastArtist = '';
    let lastVideoId = '';

    function currentVideoId() {
        const player = document.querySelector('ytmusic-player');
        const data = player?.playerApi?.getVideoData?.();
        return data?.video_id || data?.videoId || '';
    }

    function sendTrackEnded() {
        bridge.postMessage({
            type: 'TRACK_ENDED',
            videoId: lastVideoId || currentVideoId()
        });
    }

    function sendUpdate() {
        const video = document.querySelector('video');
        const progressBar = document.querySelector('#progress-bar');
        const title = /* DOM title, or player API title if DOM is stale */;
        const artist = /* DOM artist, or player API artist if DOM is stale */;
        const videoId = currentVideoId();
        const trackChanged =
            (title !== '' && (title !== lastTitle || artist !== lastArtist))
            || (videoId !== '' && videoId !== lastVideoId);

        if (trackChanged) {
            if (title !== '') {
                lastTitle = title;
                lastArtist = artist;
            }
            if (videoId !== '') {
                lastVideoId = videoId;
            }
        }

        bridge.postMessage({
            type: 'STATE_UPDATE',
            isPlaying: video ? !video.paused : false,
            progress: parseInt(progressBar?.getAttribute('value') || '0'),
            duration: parseInt(progressBar?.getAttribute('aria-valuemax') || '0'),
            title: title,
            artist: artist,
            videoId: videoId,
            trackChanged: trackChanged
        });
    }
})();
```

### Message Handler

```swift
func userContentController(_:, didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any],
          let type = body["type"] as? String
    else { return }

    Task { @MainActor in
        if type == "TRACK_ENDED" {
            await playerService.handleTrackEnded(
                observedVideoId: body["videoId"] as? String
            )
            return
        }

        playerService.updatePlaybackState(...)
        playerService.updateTrackMetadata(...)
    }
}
```

### Queue Authority

Kaset treats its own queue as the source of truth whenever one exists:
- `handleTrackEnded(observedVideoId:)` advances the native queue immediately
- `updateTrackMetadata(...)` accepts `videoId`-only transitions even if the DOM
  metadata is temporarily blank or stale
- If YouTube advances to an unexpected track near the end of a song, Kaset
  replays the expected queue track instead of inheriting YouTube autoplay
- At the end of a non-repeating queue, Kaset marks playback ended rather than
  allowing autoplay to continue into unrelated tracks

## Sidebar Video

The Now Playing right sidebar shows the music video / video podcast in place of the
artwork when the reader enables it and `hasVideoSurface` is true (see
[ADR-0032](adr/0032-sidebar-video-replaces-mini-player.md)). The sidebar re-parents the
singleton WebView with the video-focused presentation; the main window keeps a hidden 1×1
audio layer and stands down while the sidebar hosts the surface. Height follows the
observed video ratio clamped to 0.75–2.4 within the artwork's 150–520pt bounds.

## Common Issues

### Multiple Audio Streams

**Cause**: Multiple WebViews created

**Solution**: Singleton pattern ensures one WebView

### Audio Stops on Window Close

**Cause**: WebView destroyed with view hierarchy

**Solution**: `windowShouldClose` returns `false`, hides instead

### Track Not Changing

**Cause**: `updateNSView` not called

**Solution**: Pass `videoId` as parameter to trigger SwiftUI updates

### No Playback

**Cause**: User interaction required by YouTube

**Solution**: Mini player toast allows user to click play

## User Agent

We use Safari's user agent to avoid "browser not optimized" warnings:

```swift
static let userAgent = """
    Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) \
    AppleWebKit/605.1.15 (KHTML, like Gecko) \
    Version/17.0 Safari/605.1.15
    """
```

## Debugging

Enable WebView inspector in Debug builds:

```swift
#if DEBUG
    webView.isInspectable = true
#endif
```

Right-click the mini player → "Inspect Element" to debug JavaScript.

## Infinite Mix

When playing artist mixes (`RDEM...` playlists) or a playlist's / album's radio (`RDAMPL…`, the
"Start mix" the browse header names — see [api-discovery.md](api-discovery.md)), the app supports
infinite queue loading:

### How It Works

1. **Initial Load**: `playWithMix()` fetches ~50 songs via the `next` endpoint
2. **Continuation Token**: The API returns a `nextRadioContinuationData.continuation` token
3. **Auto-Fetch**: When ≤10 songs remain in queue, `fetchMoreMixSongsIfNeeded()` loads more
4. **Duplicate Filter**: New songs are filtered to prevent duplicates
5. **Repeat**: Process continues until no more continuation tokens

### Key Components

| Component | Purpose |
|-----------|----------|
| `RadioQueueResult` | Holds songs + continuation token |
| `mixContinuationToken` | Stored in `PlayerService` |
| `isFetchingMoreMixSongs` | Prevents concurrent fetches |
| `fetchMoreMixSongsIfNeeded()` | Triggered on `next()` and `playFromQueue()` |

### State Reset

The continuation token is cleared when:
- Playing a regular queue (`playQueue`)
- Playing song radio (`playWithRadio`)
- Clearing the queue (`clearQueue`)

This prevents infinite fetch from triggering on non-mix playback.

The playlist and album pages' **Start Radio** action (in the header's "…" menu) calls
`playWithMix(playlistId:startVideoId:)` with the mix playlist their header named — or, for a
playlist, the `RDAMPL` + playlist-ID target YouTube Music builds when the header names none. It
shuffles the mix and starts on a random track, the same way the artist page's **Mix** button does.

## Google Cast

Casting sends Kaset's audio to a Google Cast device; see [ADR-0015](adr/0015-chromecast-audio-casting.md) for why the
approach was chosen over the official SDK and the YouTube Lounge protocol. AirPlay is no longer offered.

Kaset stays the player: the audio the WebView decodes is captured, encoded, and served to the device's built-in
Default Media Receiver, so the queue, seeking, and track changes keep working exactly as they do locally.

| Stage | Component | Notes |
|-------|-----------|-------|
| Discovery | `CastDeviceDiscovery` | Browses `_googlecast._tcp`; name, model, and id come from the TXT record, and each device is listed the moment mDNS reports it |
| Capture | `AudioProcessTap`, `CastAudioProcessResolver` | Core Audio process tap over Kaset and WebKit's XPC helpers, muted while tapped |
| Encode | `AACStreamEncoder`, `ADTSHeader` | AAC-LC at 192 kbps, framed as `audio/aac` |
| Serve | `LocalAudioStreamServer` | Endless chunked HTTP response on an ephemeral port |
| Hand over | `CastConnection`, `CastReceiverSession` | CASTV2 over TLS to port 8009, `LOAD` on `CC1AD845` |
| Coordinate | `CastService` | Device list, session state, and the player bar's cast menu |

### Notes and limitations

- The first cast triggers the macOS local-network, firewall, and **system audio recording** prompts. Capture
  needs the audio recording permission (`kTCCServiceAudioCapture`), declared through
  `NSAudioCaptureUsageDescription` and the sandbox's audio input entitlement; the grant lives under
  System Settings → Privacy & Security → Screen & System Audio Recording. Without it the tap still runs and
  still mutes the Mac, but streams silence — the cast log calls that out explicitly.
- Audio is captured after decoding, so DRM-protected tracks, podcasts, and ads all cast unchanged.
- The Cast menu lists a device as soon as mDNS reports it — measured at ~20 ms, since nothing is resolved
  before publishing — and keeps the last known devices while a fresh browse runs, so reopening or refreshing the
  menu is instant. A browse that no longer sees a device removes it from the list.
- The slider shapes the stream rather than the device volume; a paused track simply stops sending audio.
- The device must be able to reach the Mac, so guest Wi-Fi and AP isolation block casting.
- WebKit renders playback in helper processes `launchd` owns, not the app, so the tap selects them from Core
  Audio's process list. Another WebKit-based app playing at the same time is captured too.

### When casting does not play

The cast log names the stage it stopped at, which separates the three failure modes:

```bash
log show --last 5m --predicate 'subsystem == "com.popcornfuzzy.Kaset"' --info | grep -i cast
```

| Log line | Meaning |
|----------|---------|
| `Connecting to Cast device at …` then `Never reached …` | The network blocked the control connection |
| `Connected to Cast device` then `Stream server listening on port …` | The control path works |
| `Tapping N process(es) for audio capture: …` | Which processes the tap covers; the app and WebKit's `com.apple.WebKit.GPU` should be listed |
| `Cast receiver connected to the audio stream` | The device fetched the stream URL |
| `Captured the first buffer from the audio tap` | Audio is being captured; without it the stream is empty |
| `The audio tap has captured nothing 5s after starting` | The tap is not receiving audio — the device will show a spinner forever. Start the track playing and cast again: the tap set is resolved when casting starts, and WebKit's helper must have opened the audio hardware by then. |
| `The audio tap has delivered only silence 5s after starting` | The system audio recording permission is missing. Grant it in System Settings → Privacy & Security → Screen & System Audio Recording and cast again. |

## Song/Video Variant Matching

A track often exists as both a song (`MUSIC_VIDEO_TYPE_ATV`) and a music video
(`MUSIC_VIDEO_TYPE_OMV`); playlists and radio mixes frequently carry the video. Kaset plays the
song version everywhere — queue, direct play, radio/mix, session restore — so the now-playing and
queue show the album art, and keeps the video for the sidebar video. See
[ADR-0028](adr/0028-song-video-variant-matching.md).

| Component | File | Purpose |
|-----------|------|---------|
| `SongVariantMatcher` | `Sources/Kaset/Services/Player/SongVariantMatcher.swift` | Resolves entries to the song variant, scores search candidates, caches results |
| `PlaylistPanelItemParser` | `Sources/Kaset/Services/API/Parsers/PlaylistPanelItemParser.swift` | Reads the `playlistPanelVideoWrapperRenderer` counterpart |
| `SongCounterpart` | `Sources/Kaset/Models/Song.swift` | Flat pairing stored on `Song` |

- The pairing is the API's song/video switcher when present, else a filtered song search scored on
title, artist and length (`searchSongs`).
- Resolution runs ahead of playback for the next `PlayerService.variantResolutionWindow` entries,
so a video is swapped before it starts.
- A known video counterpart makes `hasVideoSurface` true; enabling the sidebar video clicks
YouTube's Video tab. `PlayerService+WebQueueSync.canonicalPlaybackVideoId(for:)` folds the video
page's id back onto the song so the queue does not see drift and the album art is kept.
- The behavior is gated by **Settings → General → Prefer Audio (Song) Versions** (default on).

## Video Mode

For floating video window functionality, see [docs/video.md](video.md).

## Future Improvements

- [x] Queue management (next/previous)
- [x] Infinite mix loading
- [x] Video mode (floating video window)
- [x] Seek support via JavaScript
- [x] Volume control
- [x] Now Playing in Control Center (via WKWebView media session + remote commands)
