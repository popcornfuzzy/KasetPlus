# ADR-0039: Discord Rich Presence

## Status

Accepted. The sandboxed build reaches Discord through a helper it starts itself; see *The App Sandbox
and the helper* below.

## Context

[ADR-0011](0011-scrobbling-support.md) reports listening activity to Last.fm. Readers also want their
music on their Discord profile: a card under "Listening to Kaset" with the track, the artists, the
album, the artwork and a progress bar, in the shape Last.fm's now-playing card has.

There are two ways an app can put a card on a Discord account, and they are not interchangeable:

1. **Discord's local RPC.** The Discord desktop client running on the same Mac listens on a unix
   socket (`$TMPDIR/discord-ipc-0`). An app writes a framed JSON `SET_ACTIVITY` command to that socket
   and the *client* publishes the card. No account, no token, no request to Discord's servers.
2. **Discord's gateway WebSocket with a user account.** The app identifies as the user
   (`op 2 IDENTIFY` with the account's token), then sends `op 3 PRESENCE_UPDATE` frames carrying the
   activity. This is what Metrolist (Android) does — through an OAuth authorization it then reuses as a
   `Bearer` token on the user gateway, or, in earlier versions, a pasted user token.

There is also a third, superficially attractive route: **RPC over WebSocket**. Discord's local RPC server can answer on a loopback port (the documented range is `6463–6472`, `ws://127.0.0.1:PORT/?v=1&client_id=…&encoding=json`), and a loopback TCP connection is the one thing the sandbox *does* allow — verified with a sandboxed probe app that connected to `127.0.0.1:6463` successfully. It is still not a route for Kaset: Discord's own documentation calls it "a deprecated way, which is only available for old participants of private beta", and it verifies the `Origin` header against an "RPC Origin" registered on the application, which a new application has no access to. Being reachable is not the same as being open.

Option 2 is not available to us: Discord's self-bot policy says automating a normal user account outside
the OAuth2/bot API "is forbidden, and can result in an account termination if found", and Discord exposes
no OAuth scope that lets a third-party app write its own presence remotely (`activities.write` is listed
as "not currently available for apps"; `rpc.activities.write` governs the *local* RPC server and is for
approved partners). Whatever the flow in front of it, publishing presence over the user gateway is account
automation, so Kaset does not do it. Discord Rich Presence has no "sign in with Discord" step at all — the
closest thing to a login is the application the card is published under.

## Decision

Use the local RPC only, and split it the way the scrobbling pipeline is split:

- **`DiscordActivity`** — the payload, built from `Song` plus playback state. Pure and testable: title in
  `details`, artists in `state`, the album as the artwork's `large_text` (never in the artist line), the
  artwork URL as `large_image`, Kaset's own application icon as the `small_image` (with its name as
  `small_text`), `type: 2` (Listening), and the two buttons Discord allows: "Listen on YouTube Music" and
  "Get Kaset on GitHub".

  Buttons are never shown on your own card: Discord renders them for *other* readers only ("Buttons are
  only visible to other users — you cannot see buttons on your own Rich Presence", Setting Rich Presence).
  They are still sent, and Discord echoes both labels back in its `SET_ACTIVITY` reply, so the way to check
  them is a second account or a friend — not by looking at your own profile.
- **`DiscordIPCConnection`** — the transport: connects with `NWConnection` to whichever endpoint this
  build may use (Discord's own socket, or the helper on loopback), frames commands (little-endian
  opcode and length), handshakes with the application id, answers pings, and matches replies to
  commands by nonce.
- **`DiscordPresenceService`** — `@MainActor @Observable`; owns the connection, remembers the card for the
  next reconnect, and reports a `DiscordPresenceStatus` for the settings row.
- **`DiscordPresenceCoordinator`** — polls `PlayerService` every 500 ms (the `ScrobblingCoordinator`
  cadence) and publishes when the card actually changes: a new track, play/pause, a seek, a duration that
  arrived late. Nothing is re-sent for progress alone.

Two details follow from how Discord draws a card:

- **The progress bar is anchored to a playback session, not to the poll.** Discord renders the timer from
  fixed `timestamps.start`/`end` values in Unix milliseconds, so they are computed once per session
  (`now - progress`) and refreshed only on a seek or a resume. Re-sending them every poll would be wrong
  and would trip the client's update rate limit.
- **A paused card carries no timestamps.** Discord cannot freeze a timer, so sending them while paused
  would leave a counter ticking against silent audio. The card shows the track without a bar instead.

The rest of the design is Kaset's own:

- **The Application ID is a constant, not a setting.** One Kaset, one registered application:
  `DiscordApplication.id` names it, and it is public metadata rather than a secret. Asking every reader to
  register an application of their own before their music can show up was friction for no benefit — the
  settings row now only has the switch, the status and the action.

  The icon needs one more constant: Discord has no "use the application's own icon" asset key, so
  `DiscordApplication.iconURL` points at the icon the portal holds on Discord's CDN, which `small_image`
  accepts as an external URL. Replacing the icon in the portal changes its hash, and that one value has to
  follow.
- **Presence is off by default.** The card says what someone is listening to, which is theirs to publish.

## The App Sandbox and the helper

Kaset stays sandboxed (`com.apple.security.app-sandbox`), which makes the Discord socket unreachable from
the app:

- the sandbox redirects `TMPDIR` into the app's container, so `NSTemporaryDirectory()` contains no
  `discord-ipc-N` even when Discord is running;
- and an `AF_UNIX` connect to the real path is refused. Verified with a minimal signed app carrying only
  `app-sandbox` + `network.client`: `connect()` to `$TMPDIR/discord-ipc-0` fails with `EPERM`
  ("Operation not permitted").

No static entitlement lifts this: `com.apple.security.temporary-exception.files.absolute-path.read-write`
would need the machine's own `/var/folders/<hash>/T/` path, and there is no network exception for a unix
socket path outside the container.

Loopback TCP, however, **is** allowed — verified with the same probe, which connected to `127.0.0.1:6463`
from inside the sandbox. That is where the app and its helper meet.

### The helper

Kaset starts a second app bundle of its own, `Contents/Helpers/KasetPresenceBridge.app`, built from
`Sources/KasetPresenceBridge` and signed without the App Sandbox. It is the one process allowed to touch
`$TMPDIR/discord-ipc-0`. It is started only while presence is switched on and a Discord client is running
(the sandboxed app cannot look for the socket, but `NSWorkspace.runningApplications` costs nothing and the
desktop clients are the only ones that serve it), and it leaves on its own after thirty seconds with
nothing connected — so nothing is left running behind the app, and a closed Discord costs a check of a
list rather than a process and a port sweep.

Four routes were tried before this one, and the first three cannot work:

- **`SMAppService.agent(plistName:)`** — a sandboxed app may not register a launch agent at all.
  `register()` answers `SMAppServiceErrorDomain` code 1, "Operation not permitted", and `status` stays
  `.notFound`. Verified with a minimal signed app carrying only `app-sandbox` and
  `Contents/Library/LaunchAgents/<id>.plist`. Registering an item that *is* sandboxed succeeds — so the
  rule is that a sandboxed app may only register sandboxed items, which could not reach the socket
  either. `SMAppService.loginItem(identifier:)` is refused the same way.
- **A handshake file in the app's container** — an app's container belongs to that app. The unsandboxed
  helper's write of `kaset-presence-bridge.json` into `~/Library/Containers/<id>/Data/tmp` fails with
  "You don't have permission to save the file … in the folder 'tmp'".
- **Arguments or environment on the launch** — `NSWorkspace.openApplication(at:configuration:)` starts the
  helper but delivers neither `configuration.arguments` nor `configuration.environment` to it. Verified
  with a nested helper that writes `CommandLine.arguments` and its environment to a file: both arrived
  empty, however the launching app was started and whatever it passed.
- **Authenticating the peer** — `getsockopt(SOL_LOCAL, LOCAL_PEERPID)` on a loopback TCP connection fails
  with `ENOPROTOOPT` (errno 42), so the helper cannot identify the process that connected and verify its
  code signature.

What is left is a launch with no configuration at all, which works: `NSWorkspace` starting a bundle from
Kaset's own `Contents/Helpers` needs no registration, no Login Items approval, nothing to uninstall, and
the helper runs genuinely outside Kaset's sandbox (a probe launched this way reported
`APP_SANDBOX_CONTAINER_ID` unset and could write `/tmp`).

The two processes therefore **derive the same ports** from the one value they share — the host app's bundle
identifier. `BridgePort.candidates(forBundleIdentifier:)` hashes it (FNV-1a) into a run of ten ports in
`49160…57168`; the helper reads the identifier from the app bundle three directories up from its own
(`Bundle/Contents/Helpers/KasetPresenceBridge.app`), binds the first free port in the run, logs it, and
Kaset tries them in order. A port some other process holds costs one refused connection, not the feature.

Nothing authenticates the connection, and nothing needs to: like Discord's own IPC socket, the helper
accepts any local process, and the only thing that can be done through it is setting Kaset's activity card
— which Discord publishes to the world anyway.

A unix socket in the container would have been tidier than loopback TCP, but `sun_path` is 104 bytes and
the container path for an ordinary user name overflows it: the probe's `bind()` created a socket named
`discord-` and the connect then failed with `ENOENT`.

**A relay, not a second implementation.** It copies bytes between the app and the Discord socket, so
commands, events, nonces and pings behave exactly as they do in an unsandboxed build. When Discord is not
running it answers the handshake with Discord's own `ERROR` frame, so the app shows "Discord isn't running"
rather than an obscure failure. Its stderr goes nowhere when LaunchServices starts it, so it also writes to
`os.Logger` under `com.popcornfuzzy.Kaset.PresenceBridge` — `log show --predicate 'subsystem ==
"com.popcornfuzzy.Kaset.PresenceBridge"'` is how to see what it did.

Unsandboxed builds (`swift run`, how the app is developed) skip all of this and talk to the Discord socket
directly; `DiscordIPCConnection.Endpoint` is the single place that decides which.

### What is and is not verified

Covered by tests: the frame codec, the relay end to end against a real socket pair (handshake,
`SET_ACTIVITY`, reply by nonce), the "Discord isn't running" error frame, the helper counting its clients,
refusing a port another helper holds, and the derived ports being stable, distinct per app and inside their
range. `DiscordPresenceBridgeTests` covers finding the helper, or reporting none in a build without
one.

The parts no unit test can reach were checked on a signed build from `Scripts/build-app.sh` with Discord
running: the helper starts from the sandboxed app, binds a derived port, connects to `discord-ipc-0`, and
Kaset logs `Connected to Discord`. That is also the check to repeat after changing the bundle layout or the
port derivation — `swift test` runs outside a bundle and outside the sandbox, so it exercises neither.

## Consequences

### Positive

- **No credentials, no login, no account risk.** Nothing sensitive is stored, and Kaset never touches a
  Discord token or password — the Discord client publishes on its own behalf.
- **No secrets in the binary.** The Application ID and the icon URL are public metadata, and nothing else
  is needed to publish a card.
- **Testable without Discord.** The payload builder, the framing and a live handshake are covered by
  unit tests; the coordinator is driven through a fake publisher.
- **In line with the existing pipeline.** Same polling cadence, same `@MainActor @Observable` shape as
  `ScrobblingCoordinator`, so a reader who knows one knows the other.

### Negative

- **Two processes to ship and sign.** The helper is a second app bundle with its own signing step. Its
  version must follow the app's through Sparkle updates, because it lives inside the app bundle; a build
  that signs it with `Kaset.entitlements` would sandbox it and break presence quietly.
- **A process outside the sandbox exists while presence is on.** That is the price of reaching Discord's
  socket at all, and it is why the helper is deliberately dumb: it relays frames and does nothing else.
- **The artwork depends on Discord fetching an external URL.** `assets.large_image` is given a raw
  `https://i.ytimg.com/...` URL; if a client refuses to resolve it, the card keeps its text and loses the
  cover rather than the whole presence.
- **Polling.** 500 ms, the same as scrobbling and notifications, only while the feature is switched on.

### Neutral

- A Discord client that starts after Kaset is picked up within five seconds; one that quits is noticed on
  the socket's own disconnect, so the status row does not lie in between.
- Buttons and artwork are Discord-side rendering; Kaset only supplies the fields, so a card's exact
  appearance is Discord's to change.
