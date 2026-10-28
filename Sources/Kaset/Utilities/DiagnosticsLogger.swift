import Foundation
import os

/// Bundle identifier every logger reports under, which is what `log show` and Console filter on.
/// Stated once so the app's identity cannot drift between loggers.
private let kasetLogSubsystem = "com.popcornfuzzy.Kaset"

/// Centralized logging for the Kaset app.
enum DiagnosticsLogger {
    /// Logger for authentication-related events.
    static let auth = Logger(subsystem: kasetLogSubsystem, category: "Auth")

    /// Logger for API-related events.
    static let api = Logger(subsystem: kasetLogSubsystem, category: "API")

    /// Logger for WebKit-related events.
    static let webKit = Logger(subsystem: kasetLogSubsystem, category: "WebKit")

    /// Logger for player-related events.
    static let player = Logger(subsystem: kasetLogSubsystem, category: "Player")

    /// Logger for UI-related events.
    static let ui = Logger(subsystem: kasetLogSubsystem, category: "UI")

    /// Logger for notification-related events.
    static let notification = Logger(subsystem: kasetLogSubsystem, category: "Notification")

    /// Logger for AI/Foundation Models-related events.
    static let ai = Logger(subsystem: kasetLogSubsystem, category: "AI")

    /// Logger for haptic feedback-related events.
    static let haptic = Logger(subsystem: kasetLogSubsystem, category: "Haptic")

    /// Logger for network connectivity-related events.
    static let network = Logger(subsystem: kasetLogSubsystem, category: "Network")

    /// Logger for updater/general app events.
    static let updater = Logger(subsystem: kasetLogSubsystem, category: "Updater")

    /// Logger for app lifecycle and URL handling events.
    static let app = Logger(subsystem: kasetLogSubsystem, category: "App")

    /// Logger for AppleScript scripting events.
    static let scripting = Logger(subsystem: kasetLogSubsystem, category: "Scripting")

    /// Logger for Google Cast-related events.
    static let cast = Logger(subsystem: kasetLogSubsystem, category: "Cast")

    /// Logger for scrobbling-related events (Last.fm, etc.).
    static let scrobbling = Logger(subsystem: kasetLogSubsystem, category: "Scrobbling")

    /// Logger for listening history-related events.
    static let history = Logger(subsystem: kasetLogSubsystem, category: "History")

    /// Logger for Discord Rich Presence events (the local Discord client connection).
    static let discord = Logger(subsystem: kasetLogSubsystem, category: "Discord")
}
