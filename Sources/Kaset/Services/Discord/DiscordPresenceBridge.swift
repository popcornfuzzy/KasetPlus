import AppKit
import DiscordBridge
import Foundation

// MARK: - DiscordPresenceBridge

/// Kaset's presence helper: where it is, and how to start it.
///
/// The helper is a separate app bundle in `Contents/Helpers`, signed without the App Sandbox, so it
/// can reach the Discord client's socket that Kaset itself may not touch.
///
/// `SMAppService` is not used, and cannot be: a sandboxed app that tries to register a launch agent
/// or a login item gets `SMAppServiceErrorDomain` code 1 ("Operation not permitted"), and the only
/// items it may register are sandboxed ones — which could not reach the socket either. `NSWorkspace`
/// launching a bundle from Kaset's own `Contents/Helpers` has no such restriction, runs the helper
/// outside Kaset's sandbox, needs no Login Items approval and leaves nothing to uninstall.
///
/// LaunchServices hands a launched app neither arguments nor environment, so the two processes meet
/// on ports derived from Kaset's bundle identifier. See ``BridgePort`` and
/// `docs/adr/0039-discord-rich-presence.md`.
enum DiscordPresenceBridge {
    /// Name of the helper app bundle inside `Contents/Helpers`.
    static let helperName = "KasetPresenceBridge"

    /// The ports the helper may be listening on, in the order it tries to bind them.
    static var candidatePorts: [UInt16] {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return [] }
        return BridgePort.candidates(forBundleIdentifier: bundleIdentifier)
    }

    /// The helper in this app's own bundle, or `nil` in a build that has none (`swift test`).
    static var bundledHelperURL: URL? {
        self.helperURL(inAppBundle: Bundle.main.bundleURL)
    }

    /// The helper's location inside a given app bundle, when it is there.
    static func helperURL(inAppBundle appBundle: URL) -> URL? {
        let url = appBundle
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("\(Self.helperName).app", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Asks macOS to start the helper, and returns at once.
    ///
    /// The launch is deliberately not awaited: LaunchServices does not report completion for an app
    /// that never becomes a UI app, and the helper is one, so waiting would stall the connection
    /// until the helper gave up. Returns `false` when this build has no helper to start.
    @MainActor
    @discardableResult
    static func launch() -> Bool {
        guard let helper = self.bundledHelperURL else { return false }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        // A helper that finds its ports taken leaves, so a fresh instance per attempt is what lets a
        // later one bind them again.
        configuration.createsNewApplicationInstance = true

        let logger = DiagnosticsLogger.discord
        NSWorkspace.shared.openApplication(at: helper, configuration: configuration) { _, error in
            guard let error else { return }
            logger.error("Could not start the presence helper: \(error.localizedDescription, privacy: .public)")
        }

        return true
    }
}
