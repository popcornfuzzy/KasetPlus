import DiscordBridge
import Foundation

// MARK: - KasetPresenceBridge

/// Kaset's Discord presence helper.
///
/// A sandboxed app cannot reach the Discord client's IPC socket, so this process — launched by
/// Kaset from inside its own bundle and signed without the App Sandbox — owns that socket instead.
/// It is deliberately dull: it accepts Kaset on a loopback port, and relays frames. It has no
/// settings, no state of its own and no other purpose.
///
/// LaunchServices gives a launched app neither arguments nor environment, and this helper cannot
/// read anything Kaset writes, so both sides find each other by deriving the same ports from the
/// host app's bundle identifier. See ``BridgePort`` and
/// `docs/adr/0039-discord-rich-presence.md`.

/// Ignore SIGPIPE before any socket is written: a closed peer must not end the helper.
signal(SIGPIPE, SIG_IGN)

guard let host = BridgePort.hostBundleIdentifier(forHelperAt: Bundle.main.bundleURL) else {
    BridgeRelay.log("cannot tell which app bundle this helper belongs to")
    exit(64)
}

// Discord's socket lives in the user's own temporary directory, which is what this unsandboxed
// process sees.
var relay: BridgeRelay?
for port in BridgePort.candidates(forBundleIdentifier: host) {
    let candidate = BridgeRelay(discordDirectory: FileManager.default.temporaryDirectory, port: port)
    do {
        try candidate.start()
        relay = candidate
        break
    } catch {
        BridgeRelay.log("port \(port) is not available: \(error)")
    }
}

guard let relay else {
    BridgeRelay.log("every port in the run for \(host) is taken")
    exit(70)
}

// Leave when nothing is connected any more: Kaset quit, or never reached this helper. Without this
// the helper would outlive the app that started it and hold a port nobody uses.
Thread.detachNewThread {
    let idleLimit: TimeInterval = 30
    var lastSeenClient = Date()
    while true {
        Thread.sleep(forTimeInterval: 2)
        if relay.connectedClients > 0 {
            lastSeenClient = Date()
        } else if Date().timeIntervalSince(lastSeenClient) > idleLimit {
            BridgeRelay.log("leaving: nothing connected for \(Int(idleLimit))s")
            relay.stop()
            exit(0)
        }
    }
}

dispatchMain()
