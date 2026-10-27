import DiscordBridge
import Foundation
import Network

// MARK: - DiscordIPCConnection

/// A connection to Discord's Rich Presence endpoint.
///
/// Discord Rich Presence is not a web API. In a normal build the Discord client's own socket is the
/// endpoint (a unix socket in the user's temporary directory); in the sandboxed build the App
/// Sandbox puts that socket out of reach, so the endpoint is Kaset's presence helper on loopback
/// instead, and the helper relays to the client. Both speak the same protocol. See
/// `docs/adr/0039-discord-rich-presence.md`.
///
/// Frames are acknowledged by nonce: `perform` writes one command and suspends until the reply
/// carrying the same nonce arrives, or the timeout fires.
actor DiscordIPCConnection {
    /// Where the frames go.
    enum Endpoint: Sendable, Equatable {
        /// The Discord client's own socket: `discord-ipc-N` in `directory`.
        case unixSocket(directory: URL)

        /// Kaset's presence helper, which relays to the Discord client.
        case bridge(port: UInt16)

        var usesBridge: Bool {
            if case .bridge = self { return true }
            return false
        }
    }

    /// Everything that can go wrong between Kaset and the Discord client.
    enum Failure: Error, Equatable, LocalizedError {
        /// No `discord-ipc-N` socket exists, so the Discord client is not running.
        case discordNotRunning
        case connectionFailed(String)
        case timedOut
        case rejected(String)
        case closed(String)

        var errorDescription: String? {
            switch self {
            case .discordNotRunning:
                String(localized: "Discord isn't running.")
            case let .connectionFailed(message):
                String(localized: "Couldn't reach Discord: \(message)")
            case .timedOut:
                String(localized: "Discord didn't answer.")
            case let .rejected(message):
                String(localized: "Discord refused the activity: \(message)")
            case let .closed(reason):
                String(localized: "The Discord connection closed: \(reason)")
            }
        }
    }

    /// Fires once when the socket drops, with the reason. Consumed by the service, which then shows
    /// the Discord client as gone and retries later.
    nonisolated let disconnects: AsyncStream<String>

    private let disconnectContinuation: AsyncStream<String>.Continuation
    private static let queue = DispatchQueue(label: "com.popcornfuzzy.Kaset.discord-ipc")

    private var connection: NWConnection?
    private var buffer = Data()
    private var waiters: [String: CheckedContinuation<Data, any Error>] = [:]
    private var expiryTasks: [String: Task<Void, Never>] = [:]
    private var readinessWaiter: CheckedContinuation<Void, any Error>?
    private var readinessTimeout: Task<Void, Never>?
    private var isClosed = false

    init() {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.disconnects = stream
        self.disconnectContinuation = continuation
    }

    // MARK: - Connecting

    /// Opens the endpoint and performs the handshake.
    func connect(
        applicationID: String,
        endpoint: Endpoint,
        timeout: Duration = .seconds(5)
    ) async throws {
        self.isClosed = false

        let connection: NWConnection
        switch endpoint {
        case let .unixSocket(directory):
            guard let socketURL = Self.socketURL(in: directory) else {
                throw Failure.discordNotRunning
            }
            DiagnosticsLogger.discord.debug("Connecting to Discord IPC at \(socketURL.path, privacy: .public)")
            connection = NWConnection(to: .unix(path: socketURL.path), using: .tcp)

        case let .bridge(port):
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                throw Failure.connectionFailed("invalid bridge port \(port)")
            }
            connection = NWConnection(to: .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: endpointPort), using: .tcp)
        }

        self.connection = connection
        try await self.waitUntilReady(connection, timeout: timeout)
        self.startReceiving(connection)

        try await self.handshake(applicationID: applicationID, timeout: timeout)
    }

    /// Whether this process runs inside the App Sandbox.
    ///
    /// The sandbox redirects `TMPDIR` into the app's container and refuses `AF_UNIX` connects outside
    /// it, so the Discord client's socket is unreachable however the client is running. Such a build
    /// uses the helper instead.
    nonisolated static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// The socket Discord listens on: `discord-ipc-0` upward, the first one that exists.
    static func socketURL(in directory: URL) -> URL? {
        for index in 0 ..< 10 {
            let candidate = directory.appendingPathComponent("discord-ipc-\(index)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Commands

    /// Writes one command frame and waits for Discord's reply to it.
    func perform(command: Data, nonce: String, timeout: Duration = .seconds(5)) async throws -> Data {
        guard self.connection != nil, !self.isClosed else {
            throw Failure.closed("Discord IPC is not connected")
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.waiters[nonce] = continuation
            self.expiryTasks[nonce] = Task { [weak self] in
                // A cancelled timer must stay silent: the answer it was waiting for already arrived.
                do { try await Task.sleep(for: timeout) } catch { return }
                await self?.expire(nonce)
            }
            self.write(DiscordIPCFrame.Frame(opcode: .frame, payload: command))
        }
    }

    /// Closes the socket and fails anything still waiting on it.
    func close() {
        self.finish(reason: "Kaset closed the connection")
    }

    // MARK: - Handshake

    private func waitUntilReady(_ connection: NWConnection, timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.readinessWaiter = continuation
            self.readinessTimeout = Task { [weak self] in
                // A cancelled timer must stay silent. Cancelling does not stop the task, so without
                // this the timer would fail the *next* handshake the moment its own was answered.
                do { try await Task.sleep(for: timeout) } catch { return }
                await self?.settleReadiness(with: .failure(Failure.timedOut))
            }

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { await self?.settleReadiness(with: .success(())) }
                case let .failed(error):
                    Task { await self?.settleReadiness(with: .failure(Failure.connectionFailed(error.localizedDescription))) }
                case let .waiting(error):
                    Task { await self?.settleReadiness(with: .failure(Failure.connectionFailed(error.localizedDescription))) }
                default:
                    break
                }
            }
            connection.start(queue: Self.queue)
        }
    }

    private func handshake(applicationID: String, timeout: Duration) async throws {
        let payload = try JSONSerialization.data(withJSONObject: ["v": 1, "client_id": applicationID])

        try await withCheckedThrowingContinuation { continuation in
            self.readinessWaiter = continuation
            self.readinessTimeout = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                await self?.settleReadiness(with: .failure(Failure.timedOut))
            }
            self.write(DiscordIPCFrame.Frame(opcode: .handshake, payload: payload))
        }
    }

    /// Resumes the pending handshake exactly once — whichever comes first, Discord's answer or the
    /// timeout.
    private func settleReadiness(with result: Result<Void, any Error>) {
        self.readinessTimeout?.cancel()
        self.readinessTimeout = nil
        guard let waiter = self.readinessWaiter else { return }
        self.readinessWaiter = nil
        switch result {
        case .success:
            waiter.resume()
        case let .failure(error):
            waiter.resume(throwing: error)
        }
    }

    // MARK: - Reading

    private func startReceiving(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { await self?.handleReceived(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceived(data: Data?, isComplete: Bool, error: (any Error)?) {
        if let data, !data.isEmpty {
            self.buffer.append(data)
            for frame in DiscordIPCFrame.drain(from: &self.buffer) {
                self.handle(frame)
            }
        }

        if let error {
            self.finish(reason: error.localizedDescription)
            return
        }

        guard !self.isClosed else { return }
        if isComplete {
            self.finish(reason: "Discord closed the connection")
            return
        }
        if let connection = self.connection {
            self.startReceiving(connection)
        }
    }

    private func handle(_ frame: DiscordIPCFrame.Frame) {
        switch DiscordIPCFrame.Opcode(rawValue: frame.opcode) {
        case .frame:
            self.handleDispatch(frame.payload)
        case .ping:
            self.write(DiscordIPCFrame.Frame(opcode: .pong, payload: frame.payload))
        case .close:
            self.finish(reason: Self.closeReason(from: frame.payload))
        default:
            break
        }
    }

    private func handleDispatch(_ payload: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return
        }

        let event = object["evt"] as? String
        if event == "READY" {
            self.settleReadiness(with: .success(()))
            return
        }

        // Anything else that arrives before the handshake finished is Discord turning it down —
        // an unknown application id, or the helper reporting that the Discord client is not running.
        if self.readinessWaiter != nil {
            let message = (object["data"] as? [String: Any])?["message"] as? String
                ?? event
                ?? "unknown response"
            self.settleReadiness(with: .failure(Failure.rejected(message)))
            return
        }

        guard let nonce = object["nonce"] as? String,
              let waiter = self.waiters.removeValue(forKey: nonce)
        else { return }

        self.expiryTasks.removeValue(forKey: nonce)?.cancel()
        waiter.resume(returning: payload)
    }

    // MARK: - Writing

    private func write(_ frame: DiscordIPCFrame.Frame) {
        guard let connection = self.connection else { return }
        let data = DiscordIPCFrame.encode(frame)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { await self?.finish(reason: error.localizedDescription) }
        })
    }

    private func expire(_ nonce: String) {
        self.expiryTasks.removeValue(forKey: nonce)?.cancel()
        guard let waiter = self.waiters.removeValue(forKey: nonce) else { return }
        waiter.resume(throwing: Failure.timedOut)
    }

    private func finish(reason: String) {
        guard !self.isClosed else { return }
        self.isClosed = true

        self.connection?.stateUpdateHandler = nil
        self.connection?.cancel()
        self.connection = nil
        self.buffer.removeAll()

        self.settleReadiness(with: .failure(Failure.closed(reason)))

        let expiryTasks = self.expiryTasks
        self.expiryTasks.removeAll()
        for task in expiryTasks.values {
            task.cancel()
        }

        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(throwing: Failure.closed(reason))
        }

        DiagnosticsLogger.discord.info("Discord IPC closed: \(reason, privacy: .public)")
        self.disconnectContinuation.yield(reason)
        self.disconnectContinuation.finish()
    }

    private static func closeReason(from payload: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let message = object["message"] as? String
        else { return "Discord closed the connection" }
        return message
    }
}
