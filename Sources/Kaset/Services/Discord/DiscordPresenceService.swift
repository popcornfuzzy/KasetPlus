import AppKit
import DiscordBridge
import Foundation
import Observation

// MARK: - DiscordPresenceStatus

/// What the Discord settings row says about Kaset's connection to the Discord client.
enum DiscordPresenceStatus: Equatable, Sendable {
    /// Switched off.
    case off

    /// No Discord client is running — the socket is not there.
    case waitingForDiscord

    case connecting
    case connected

    /// The connection failed for a reason worth showing: Discord refused the activity.
    case failed(String)

    /// This build has no presence helper, so a sandboxed app has no way to reach Discord.
    case bridgeUnavailable

    var isConnected: Bool {
        self == .connected
    }
}

// MARK: - DiscordPresencePublishing

/// What the coordinator needs from Discord. A protocol so the polling logic can be exercised
/// without a Discord client running.
@MainActor
protocol DiscordPresencePublishing: AnyObject {
    var status: DiscordPresenceStatus { get }

    /// Connects when the feature is on and configured, and closes the socket when it is not.
    func ensureConnected() async

    /// Sets the card, or clears it when `activity` is `nil`.
    func publish(_ activity: DiscordActivity?) async
}

// MARK: - DiscordPresenceService

/// Owns the connection to Discord and the activity Kaset last set.
///
/// The coordinator decides *what* to show; this service only carries it over the socket, keeps it
/// for the next reconnect, and reports what state the connection is in.
///
/// In a sandboxed build the frames go to Kaset's presence helper on loopback, because the App
/// Sandbox refuses the Discord client's socket; the helper relays them. In an unsandboxed build
/// (`swift run`) the Discord socket is used directly.
@MainActor
@Observable
final class DiscordPresenceService: DiscordPresencePublishing {
    private(set) var status: DiscordPresenceStatus = .off

    /// The card currently set, so a reconnect can put it back.
    private(set) var activity: DiscordActivity?

    private let settings: SettingsManager
    private let logger = DiagnosticsLogger.discord

    private var connection: DiscordIPCConnection?
    private var disconnectWatcher: Task<Void, Never>?

    init(settings: SettingsManager = .shared) {
        self.settings = settings
    }

    // MARK: - Lifecycle

    func ensureConnected() async {
        guard self.settings.discordRichPresenceEnabled else {
            if self.connection != nil {
                await self.closeConnection()
            }
            self.status = .off
            return
        }

        guard !self.status.isConnected || self.connection == nil else { return }

        guard DiscordIPCConnection.isSandboxed else {
            await self.connect(using: .unixSocket(directory: FileManager.default.temporaryDirectory))
            return
        }

        // Nothing is started and no port is asked while Discord is closed: the running-application
        // list says so for free, and a helper would only relay to a socket that is not there.
        guard Self.isDiscordRunning else {
            self.status = .waitingForDiscord
            return
        }

        // The helper listens on one of a known run of ports, and a port it did not get is refused at
        // once, so asking them is cheap. Only when none answers is it started — a running helper is
        // used as it is, rather than a second copy being spawned beside it.
        for port in DiscordPresenceBridge.candidatePorts {
            if await self.connect(using: .bridge(port: port)) { return }
        }

        guard DiscordPresenceBridge.launch() else {
            self.status = .bridgeUnavailable
            return
        }

        // The helper binds a moment after it starts; the next pass finds it.
        self.status = .connecting
    }

    /// Closes the socket and clears the card. The helper leaves on its own once nothing is
    /// connected to it, so there is nothing to unregister.
    func shutdown() async {
        self.activity = nil
        await self.closeConnection()
        self.status = .off
    }

    // MARK: - Publishing

    func publish(_ activity: DiscordActivity?) async {
        self.activity = activity
        guard self.settings.discordRichPresenceEnabled else { return }

        if self.connection == nil {
            await self.ensureConnected()
        }
        guard let connection = self.connection else { return }

        do {
            try await self.send(activity, over: connection)
        } catch {
            self.logger.warning("Discord activity update failed: \(error.localizedDescription, privacy: .public)")
            await self.closeConnection()
            self.status = Self.status(after: error, usingBridge: DiscordIPCConnection.isSandboxed)
        }
    }

    // MARK: - Connecting

    @discardableResult
    private func connect(using endpoint: DiscordIPCConnection.Endpoint) async -> Bool {
        self.status = .connecting
        let connection = DiscordIPCConnection()

        do {
            try await connection.connect(applicationID: DiscordApplication.id, endpoint: endpoint)
        } catch {
            await connection.close()
            self.status = Self.status(after: error, usingBridge: endpoint.usesBridge)
            self.logger.debug("Discord IPC connect failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        self.connection = connection
        self.status = .connected
        self.logger.info("Connected to Discord")

        self.watchForDisconnect(connection)

        if let activity = self.activity {
            try? await self.send(activity, over: connection)
        }

        return true
    }

    private func send(_ activity: DiscordActivity?, over connection: DiscordIPCConnection) async throws {
        let request = DiscordIPCRequest(activity: activity, nonce: UUID().uuidString)
        let payload = try JSONEncoder().encode(request)
        _ = try await connection.perform(command: payload, nonce: request.nonce)
    }

    private func closeConnection() async {
        self.disconnectWatcher?.cancel()
        self.disconnectWatcher = nil
        let connection = self.connection
        self.connection = nil
        await connection?.close()
    }

    /// Watches the socket so a Discord client that quits is noticed even while nothing is playing.
    private func watchForDisconnect(_ connection: DiscordIPCConnection) {
        self.disconnectWatcher?.cancel()
        self.disconnectWatcher = Task { [weak self] in
            for await reason in connection.disconnects {
                guard let self else { return }
                await self.handleDisconnect(reason, from: connection)
                return
            }
        }
    }

    private func handleDisconnect(_ reason: String, from connection: DiscordIPCConnection) async {
        guard self.connection === connection else { return }
        self.connection = nil
        self.status = .waitingForDiscord
        self.logger.info("Lost the Discord client: \(reason, privacy: .public)")
    }

    private static func status(after error: any Error, usingBridge: Bool) -> DiscordPresenceStatus {
        guard let failure = error as? DiscordIPCConnection.Failure else {
            return .failed(error.localizedDescription)
        }

        switch failure {
        case .discordNotRunning:
            return .waitingForDiscord
        case let .rejected(message):
            // The helper reports a missing Discord client with the same message Discord itself
            // would have used for its own error frame.
            if usingBridge, message == BridgeRelay.discordNotRunningMessage {
                return .waitingForDiscord
            }
            return .failed(message)
        case let .connectionFailed(message):
            // Through the helper, "nothing on that port" means it is still coming up: Discord not
            // running arrives as its own error frame instead, which reads as `.waitingForDiscord`.
            return usingBridge ? .connecting : .failed(message)
        case .timedOut:
            return .failed(String(localized: "Discord didn't answer."))
        case let .closed(reason):
            return usingBridge ? .waitingForDiscord : .failed(reason)
        }
    }

    /// Whether a Discord client that serves the local RPC socket is running.
    ///
    /// The desktop clients are the ones that serve it; a browser tab or a web-based wrapper has no
    /// socket for Kaset to relay to, so none of them is worth starting the helper for.
    private static var isDiscordRunning: Bool {
        let clients: Set<String> = ["com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary"]
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier.map(clients.contains) ?? false
        }
    }
}

// MARK: - DiscordIPCRequest

/// One `SET_ACTIVITY` command, as Discord's IPC protocol expects it.
///
/// `activity` is written even when it is `nil`: that null is how a card is cleared, and omitting the
/// key would leave the last one up.
struct DiscordIPCRequest: Encodable, Sendable {
    struct Args: Encodable, Sendable {
        let pid: Int32
        let activity: DiscordActivity?

        enum CodingKeys: String, CodingKey {
            case pid
            case activity
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.pid, forKey: .pid)
            if let activity = self.activity {
                try container.encode(activity, forKey: .activity)
            } else {
                try container.encodeNil(forKey: .activity)
            }
        }
    }

    let cmd = "SET_ACTIVITY"
    let args: Args
    let nonce: String

    init(activity: DiscordActivity?, nonce: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.args = Args(pid: pid, activity: activity)
        self.nonce = nonce
    }
}
