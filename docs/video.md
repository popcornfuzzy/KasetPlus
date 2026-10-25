# Video Mode

This document details the floating video window feature.

## Overview

Video Mode allows users to watch music videos in a floating window while using other apps. The feature leverages the same singleton WebView used for audio playback to display video content.

## Architecture

### Components

| Component | File | Purpose |
|-----------|------|---------|
| `VideoWindowController` | `Sources/Kaset/VideoWindowController.swift` | Manages the floating video window lifecycle |
| `VideoPlayerWindow` | `Sources/Kaset/Views/VideoPlayerWindow.swift` | SwiftUI view for video display |
| `VideoContainerView` | `Sources/Kaset/Views/VideoPlayerWindow.swift` | NSView container that hosts the WebView |
| `SingletonPlayerWebView+VideoMode` | `Sources/Kaset/Views/SingletonPlayerWebView+VideoMode.swift` | CSS injection for video extraction |

### Display Modes

The `SingletonPlayerWebView` supports three display modes:

```swift
enum DisplayMode {
    case hidden     // 1×1 pixel, audio-only playback
    case miniPlayer // 160×90 pixel toast for user interaction
    case video      // Full-size video in floating window
}
```

## Video Window Features

### Window Properties

| Property | Value | Reason |
|----------|-------|--------|
| `level` | `.normal` | Standard window (not always-on-top) |
| `collectionBehavior` | `[.canJoinAllSpaces, .fullScreenAuxiliary]` | Visible on all Spaces, works with fullscreen apps |
| `aspectRatio` | `16:9` | Maintains video aspect ratio during resize |
| `minSize` | `320×180` | Minimum readable size |
| `backgroundColor` | `.black` | Letterbox color for non-16:9 content |

### Corner Snapping

The video window remembers its position across sessions:
- Position is saved to `UserDefaults` when window closes
- Window repositions to nearest corner (top-left, top-right, bottom-left, bottom-right)
- Default corner: bottom-right

## Video Extraction

When entering video mode, JavaScript extracts the `<video>` element from YouTube Music's DOM:

### Injection Flow

1. **Inject Blackout CSS**: Immediately covers the page with a black overlay to prevent UI flash
2. **Click Video Tab**: Attempts to click YouTube Music's "Video" toggle (if available)
3. **Create Container**: Creates `#kaset-video-container` with `position: fixed`
4. **Move Video**: Moves `<video>` element into the container
5. **Disable Controls**: Sets `video.controls = false` (users control via app's player bar)
6. **Block Click Events**: Prevents clicks from reaching YouTube's underlying handlers
7. **Apply Volume**: Syncs video volume with app's volume setting
8. **Remove Blackout**: Shows the extracted video

### CSS Strategy

```javascript
container.style.cssText = `
    position: fixed !important;
    top: 0 !important;
    left: 0 !important;
    width: ${containerWidth}px !important;
    height: ${containerHeight}px !important;
    z-index: 2147483647 !important;
`;
```

The container uses explicit pixel values (not viewport units) because WKWebView viewport units don't update reliably on resize. `refreshVideoModeCSS()` is called on resize to update dimensions.

## Resize Handling

On window resize:
1. `refreshVideoModeCSS()` is called
2. Updates container and video element to new pixel dimensions
3. No re-extraction of the video element is performed

## Window Lifecycle

### Opening Video Window

```
User clicks Video button
    → PlayerService.showVideo = true
    → MainWindow.onChange() calls VideoWindowController.show()
    → VideoWindowController creates NSWindow + VideoPlayerWindow
    → SingletonPlayerWebView.updateDisplayMode(.video)
    → injectVideoModeCSS() extracts video to fullscreen container
```

### Closing Video Window

```
User clicks close button (red X)
    → NSWindow.willCloseNotification fires
    → windowWillClose() saves corner position
    → performCleanup() calls updateDisplayMode(.hidden)
    → removeVideoModeCSS() restores video to original location
    → PlayerService.showVideo = false
```

### Track Changes

When a new track starts while video window is open:
- Video window closes automatically (after a 3-second grace period for initial load)
- User can reopen for the new track
- This prevents showing wrong video for the audio

The grace period prevents the video from closing during the initial `trackChanged` events that fire when the video is first loaded.

## Known Issues & Solutions

### Issue: The Sidebar Video Blinks Black, or Shows the Page's Player (FIXED)

**Root cause**: the surface trusted the page too much. The picture is the YouTube Music page's
own `<video>` element, moved into a container the app draws, so anything that page does to that
element between two of the app's looks at it was invisible to the app:

- The healing watchdog ran **once a second** and only asked whether *some* video was still a child
  of the container. YouTube replaces that element when it re-renders its player (a Song/Video
  switch finishing late, an adaptive-stream swap). If the replacement happened while the old node
  stayed in the container, the check reported a healthy surface while the container held a dead
  node — a **black box that never healed**, for the rest of the track.
- The page's own player chrome could be painted into the surface at all: a navigation replaces the
  document, and the container and blackout go with it, so the surface drew the raw page until the
  presentation was re-applied after the load finished (the flash of the YouTube Music player with
  its "Video" tab and title overlay).
- The surface was swapped under `AppAnimation.standard`, so its height was animated. A `WKWebView`
  resized on every frame of a curve repaints asynchronously, so the picture could be black or
  half-drawn while it grew.
- Re-applying the presentation re-ran the video-tab click. On a control that is a toggle rather
  than a tab, a second click switches the picture away; the click also restarts the player's video.

**Solution**: the surface is now guaranteed to show either the picture or nothing of the page —
never the page itself, and never a picture the page has already replaced.

- Healing is a **microtask driven by a `MutationObserver`**, so it runs after the task that broke
  the picture and before the browser paints: a replaced element is swapped in during the same task
  that replaced it. A `loadeddata`/`playing` capture listener covers a video that decodes its first
  frame with no DOM change at all, and a two-second interval is left as a safety net for a page
  that defeats both.
- Liveness is *the element that is playing*, not "a video is in the container"
  (`currentVideo()`/`containerShowsCurrentVideo()`). A dead node is replaced, and any other video in
  the container is removed, so exactly one picture can ever be drawn.
- `showCurrentVideo()` is the **only** thing that uncovers the page (it removes the blackout and the
  presentation cover), so the page's chrome cannot appear before there is a picture to replace it.
- The presentation state is remembered in `sessionStorage`, and
  `SingletonPlayerWebView.presentationCoverScript` covers a newly loaded document at parse time —
  a page load in the video surface is black until the picture is up, not a flash of YouTube Music.
- The extracted video is pinned with `position: absolute; inset: 0; transform: none`, so a size or
  transform written by the page's own player cannot offset the picture inside the surface.
- The WebView's *view hierarchy* follows the same single-writer rule as its DOM presentation
  (`PlayerSurfaceOwnership.mayHost`): a parking host (the invisible 1×1 audio layer) may not move
  the WebView into its own container while a video surface owns the presentation. The parking layer
  is re-mounted for a single update whenever `isSidebarVideoShowing` briefly reads false — a track
  change, a metadata refresh — and taking the WebView then left the sidebar drawing a black box,
  because the sidebar's representable is not updated afterwards (none of its inputs changed) and so
  nothing moved the WebView back.
- The video-tab click is **once per document** (`__kasetVideoTabClicked`), and the retry loop around
  it only runs while the player is being built.
- The sidebar swaps artwork and video with no animation at all: a live `WKWebView` cannot be
  resized per frame without painting glitches, and the picture never passes through a shape it will
  not have again.

Pinned by `VideoPresentationScriptTests`: a replaced element is shown in the same task, a dead node
is replaced by the playing one, the page stays covered until the video has a frame, and a loaded
document covers itself only while the surface is showing.

### Issue: Black Bars Around the Video Right After Switching to It (FIXED)

**Root cause**: the sidebar sizes its video surface from the picture's own ratio, but that ratio was
only *requested* when a surface attached — and the picture was uncovered in the same breath. For the
first frames after a switch the surface was therefore still the 16:9 fallback, and `object-fit: contain`
letterboxed anything that is not 16:9 inside it: the frame of black around the picture that
disappears as soon as the box takes the video's real shape. Learning the shape only after the switch
is what made it depend on timing, and revealing the picture immediately (rather than after the old
150 ms extraction timer) made it show up more often.

A second, smaller defect fed the same symptom: `makeNSView` runs before SwiftUI lays its view out, so
the shared WebView could be hosted — and the page's viewport built — at **0×0**, then resized once
layout arrived. The picture was therefore painted in a box that was not the surface yet.

**Solution**: the shape is known before the picture is shown, and the picture never fills a box that
is not its own shape.

- The page reports the picture's shape as soon as it draws one (`reportPictureShape()` in the
  presentation script, `VIDEO_DIMENSIONS` → `PlayerService.updateMiniPlayerVideoDimensions`), also
  while the video is only playing in the invisible layer. The surface is drawn to that shape from
  its first frame, so there is no fallback box to letterbox inside.
- A surface whose shape is still unknown fills instead of letterboxing
  (`NowPlayingSidebarView.sidebarVideoFillsSurface(for:)`): covering a 16:9 box during those few
  frames is invisible, a black bar is not. Once the shape is known the usual rule applies (`cover`
  when the box is the picture's shape, `contain` when the column imposed one).
- `SingletonPlayerWebView.ensureInHierarchy` refuses to host the WebView in a view that has no size,
  and `PlayerHostView` reports its layout so the host takes the WebView once it does. The page is
  never built at 0×0 and never resized afterwards.

### Issue: Black Hairline Around the Sidebar Video (FIXED)

**Root Cause**: The surface and the page drawn in it disagreed about the picture's shape. The
sidebar sizes its video surface from the content's ratio, but (1) the height was fractional — a
300pt column over an 854×480 video asked for 168.6pt while the page laid the surface out in whole
points — and (2) that ratio was *remembered for the playback* rather than for the video, so any
reclassification of the same song (an API verdict, a podcast reconciliation) dropped it and the
surface fell back to 16:9 mid-video. Either way `object-fit: contain` letterboxed the picture
inside a box that was not its shape, and the whole picture shrank by a couple of points: the black
around it was that letterbox, plus the surface's own background outside the page's viewport.

**Solution**: the shape belongs to the video, and a surface that is the video's own shape *fills*
it. Concretely:

- The ratio is tagged with the video it was read from (`PlayerService.miniPlayerVideoAspectRatioVideoId`)
  and survives reclassifying that video; a different video drops it.
- A surface asks the page for the picture's size when it attaches and the app does not know it for
  that video (`SingletonPlayerWebView.requestVideoDimensions()` → `VIDEO_DIMENSIONS`), so the shape
  is known before the first frame instead of whenever the next state update carries it.
- The surface height is whole points
  (`SidebarVideoAspect.box(forWidth:observedAspectRatio:availableHeight:reservedHeight:)`), so the
  page's viewport is exactly the surface.
- A matching surface uses `object-fit: cover` (through `PersistentPlayerView.fillsSurface`) instead
  of letterboxing the picture into itself. A surface whose ratio the column imposed — the fallback
  before the video reports its own, a clamped portrait, a short column, and the fullscreen podcast
  slot's fixed 16:9 — keeps `contain`, so the whole picture stays visible there.

### Issue: The Picture Arrives Small, Centred in Black (FIXED)

**Root Cause**: the WebView was parked in the invisible 1×1 layer while the artwork was shown and
hosted again at the video's size on every toggle. A page lays out in CSS pixels, but the video's
own rendering layer (the one the GPU process draws the frames into) adopts the element's new size
asynchronously — and for the first ~370 ms after a WebView resize it is still drawn at the size the
page had before. Measured on the real page with a screen recording at 54 fps: the surface is
300×169 pt, the picture is drawn at 169×95 pt in the middle of it for 20 frames, and the DOM
reported the video at `0,0,300,169` with `object-fit: cover` on every one of them (the elements,
the attributes and the container never changed), so nothing in the page can see or correct it. That
is the frame of black around a shrunken picture right after switching to the video.

**Solution**: a surface that is never resized never draws a frame at the wrong size, so the sidebar
keeps the video's WebView instead of parking it. Concretely:

- `NowPlayingSidebarView.mediaSection` mounts `NowPlayingSidebarVideo` whenever the sidebar has a
  video, and shows the artwork *above* it; the toggle is an opacity change, not a host handoff.
  The media slot is clipped to the artwork's height, so a portrait video taller than the artwork
  does not stretch the column while the artwork is shown and the WebView keeps its frame either way.
- `SidebarVideoHosting.keepsSurface(isSidebarVisible:hasVideoSurface:hasPendingVideo:isFullscreenPodcastPresented:)`
  is the one rule for that, shared by the sidebar and the window (the hidden 1×1 layer stands down
  while the sidebar holds the surface, exactly as it does while the sidebar video is showing).
- The fullscreen podcast view keeps its own slot and its own surface: the sidebar does not hold the
  WebView while it is presented, or two hosts would claim the one WebView.

The cost is that the video keeps decoding behind the artwork while the column is open; it is the
same stream that is already playing its audio.

### Issue: Video Turns Off on Resize (FIXED)

**Root Cause**: The `hasVideo` detection in the JavaScript observer became unreliable when video mode was active. When the video element was extracted from the DOM or the Song/Video toggle buttons were hidden by our CSS, the observer would report `hasVideo=false`. The `updateVideoAvailability` function would then auto-close the video window.

**Solution**: Removed the auto-close behavior from `updateVideoAvailability`. The video window now only closes when:
1. User explicitly closes it (red X button)
2. Track changes (handled by `trackChanged` in the Coordinator)
3. User toggles `showVideo` off

The `hasVideo` property is still updated and used to enable/disable the Video button in the UI, but it no longer affects an already-open video window.

### Issue: Volume Jump When Opening Video (FIXED)

**Root Cause**: YouTube's internal player APIs and the HTML5 video element have separate volume states. Moving the video element or clicking the Video tab could cause YouTube to reset volume.

**Solution**: Volume enforcement via multiple mechanisms:
1. `window.__kasetTargetVolume` stores the app's target volume
2. `volumechange` event listener enforces the target volume (with debouncing)
3. Volume is applied via three APIs: `video.volume`, `playerApi.setVolume()`, and `movie_player.setVolume()`
4. Click events on the video container are blocked to prevent YouTube's handlers from changing volume
5. Volume is reapplied after video extraction completes

### Issue: UI Flash When Opening Video (FIXED)

**Root Cause**: When entering video mode, YouTube's web UI was briefly visible before video extraction completed.

**Solution**: Inject a blackout overlay (`#kaset-blackout`) immediately when entering video mode. This black `<div>` covers the entire viewport until video extraction is complete.

### Issue: Volume Wrong on Song Start (FIXED)

**Root Cause**: The WKUserScript for volume initialization was created at WebView creation time, capturing a stale volume value. When pages reloaded for new songs, this stale script ran.

**Solution**: 
1. Removed static volume init script from WebView configuration
2. `didFinish` navigation delegate applies current volume dynamically
3. Observer script applies `__kasetTargetVolume` when video element is first detected

### Issue: Video Availability

**Root Cause**: Not all songs have music videos available.

**Solution**: `PlayerService.currentTrackHasVideo` tracks video availability using a hybrid detection approach. The Video button is only enabled when a video exists.

## Video Detection

Video availability is detected using a **hybrid approach** with two sources:

### 1. API-Based Detection (Authoritative)

When `fetchSongMetadata` is called, the parser extracts `musicVideoType` from the YouTube Music API response:

```swift
// Response path (next endpoint):
navigationEndpoint.watchEndpoint.watchEndpointMusicSupportedConfigs
    .watchEndpointMusicConfig.musicVideoType
```

The `MusicVideoType` enum classifies content:

| Value | Enum Case | Has Video |
|-------|-----------|-----------|
| `MUSIC_VIDEO_TYPE_OMV` | `.omv` | ✅ Yes |
| `MUSIC_VIDEO_TYPE_ATV` | `.atv` | ❌ No (audio track video) |
| `MUSIC_VIDEO_TYPE_UGC` | `.ugc` | ❌ No (user-generated placeholder) |
| `MUSIC_VIDEO_TYPE_PODCAST_EPISODE` | `.podcastEpisode` | ❌ No |

Only Official Music Videos (OMV) have actual video content. ATV tracks show a static album art "video."

**Files**:
- [Sources/Kaset/Models/MusicVideoType.swift](../Sources/Kaset/Models/MusicVideoType.swift) — Enum definition with `hasVideoContent` property
- [Sources/Kaset/Services/API/Parsers/SongMetadataParser.swift](../Sources/Kaset/Services/API/Parsers/SongMetadataParser.swift) — `parseMusicVideoType(from:)` method
- [Sources/Kaset/Services/Player/PlayerService+Library.swift](../Sources/Kaset/Services/Player/PlayerService+Library.swift) — Calls `updateVideoAvailability(hasVideo:)` after parsing

### 2. DOM-Based Detection (Fast Fallback)

The JavaScript observer in the WebView provides immediate feedback before the API call completes:

```javascript
// Detects Song/Video toggle button
const toggleButton = document.querySelector('#tab-renderer tp-yt-paper-tab:nth-child(2)');
const hasVideo = toggleButton != null;
```

This is a **fallback** mechanism because:
- DOM detection fires immediately when the WebView loads the page
- API detection requires a network round-trip to the `next` endpoint
- DOM detection can be unreliable when video mode CSS is injected

**File**: [Sources/Kaset/Views/SingletonPlayerWebView+ObserverScript.swift](../Sources/Kaset/Views/SingletonPlayerWebView+ObserverScript.swift)

### Detection Flow

```
Track starts playing
    ├── DOM observer fires immediately
    │   └── PlayerService.updateVideoAvailability() called (fast, may be inaccurate)
    │
    └── fetchSongMetadata() completes
        └── musicVideoType parsed
            └── PlayerService.updateVideoAvailability() called (authoritative)
```

The API-based detection overwrites any earlier DOM-based value, providing the correct authoritative result.

## Debugging

### Enable WebView Inspector

In Debug builds, right-click the video window and select "Inspect Element":

```swift
#if DEBUG
    webView.isInspectable = true
#endif
```

### Check Video State

The injection script returns diagnostic info:

```javascript
return {
    success: true,
    videoWidth: video.videoWidth,
    videoHeight: video.videoHeight,
    volume: video.volume
};
```

### Logs

Video-related logs use `DiagnosticsLogger.player`:
- `"Singleton WebView finished loading: ..."` — Page navigation complete
- `"Video restored to original location"` — Cleanup completed

## Future Improvements

- [ ] Picture-in-Picture API integration (native macOS PiP)
- [ ] Keyboard shortcuts for video controls
- [ ] Fullscreen video mode
- [ ] Remember window size (not just corner)
- [ ] Video quality selection (requires WebView JavaScript injection to access streamingData formats)
