import Darwin
import Foundation
import os

// MARK: - BridgeRelay

/// The helper's whole job: accept the app on loopback, then relay its frames to the Discord client
/// and Discord's answers back.
///
/// The relay does not interpret the RPC conversation — it copies bytes, so commands, events, nonces
/// and pings all keep working exactly as they do over Discord's own socket.
///
/// It accepts any local process, like Discord's own IPC socket does. All that can be done through it
/// is setting an activity card under Kaset's public application id, and Discord itself publishes
/// that card to the world.
///
/// When Discord is not running the relay answers the app's handshake with an `ERROR` frame saying so,
/// instead of closing without a word.
public final class BridgeRelay: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case socket(String)
        case bind(String)
        case listen(String)

        public var description: String {
            switch self {
            case let .socket(message): "socket() failed: \(message)"
            case let .bind(message): "bind() failed: \(message)"
            case let .listen(message): "listen() failed: \(message)"
            }
        }
    }

    /// Message the app receives when the Discord client is not there.
    public static let discordNotRunningMessage = "Discord isn't running"

    private let discordDirectory: URL
    private let requestedPort: UInt16
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var isRunning = false
    private var listeningPort: UInt16 = 0
    private let clientLock = NSLock()
    private var clientCount = 0

    /// - Parameters:
    ///   - discordDirectory: Where the Discord client keeps `discord-ipc-N` (the helper's own
    ///     temporary directory, since it is not sandboxed).
    ///   - port: The loopback port to listen on, or 0 to let the system pick one.
    public init(discordDirectory: URL, port: UInt16 = 0) {
        self.discordDirectory = discordDirectory
        self.requestedPort = port
    }

    /// The port the relay is listening on, once ``start()`` has returned.
    public var boundPort: UInt16 {
        self.lock.withLock { self.listeningPort }
    }

    // MARK: - Lifecycle

    /// Binds the loopback port and starts accepting.
    public func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(String(cString: strerror(errno))) }

        do {
            try Self.bindLoopback(fd, port: self.requestedPort)
        } catch {
            close(fd)
            throw error
        }

        guard Darwin.listen(fd, 4) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw Failure.listen(message)
        }

        let port = Self.boundPort(of: fd)
        self.lock.withLock {
            self.listenFD = fd
            self.isRunning = true
            self.listeningPort = port
        }

        Self.log("listening on 127.0.0.1:\(port)")
        Thread.detachNewThread { [self] in self.acceptLoop(fd) }
    }

    /// Stops accepting and closes the socket.
    public func stop() {
        let fd: Int32 = self.lock.withLock {
            let fd = self.listenFD
            self.listenFD = -1
            self.isRunning = false
            return fd
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    // MARK: - Accepting

    private var running: Bool {
        self.lock.withLock { self.isRunning }
    }

    /// How many connections are being served right now. The helper leaves once this stays at zero,
    /// which is how it notices that Kaset is gone.
    public var connectedClients: Int {
        self.clientLock.withLock { self.clientCount }
    }

    private func acceptLoop(_ fd: Int32) {
        while self.running {
            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                break
            }
            Self.noSigPipe(client)
            Thread.detachNewThread { [self] in self.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        self.clientLock.withLock { self.clientCount += 1 }
        defer {
            self.clientLock.withLock { self.clientCount -= 1 }
            close(client)
        }

        guard let discord = self.connectToDiscord() else {
            self.sendError(to: client)
            return
        }
        defer { close(discord) }

        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            Self.pump(from: client, to: discord)
            finished.signal()
        }
        Thread.detachNewThread {
            Self.pump(from: discord, to: client)
            finished.signal()
        }
        finished.wait()
        finished.wait()
    }

    // MARK: - Discord

    private func connectToDiscord() -> Int32? {
        for index in 0 ..< 10 {
            let path = self.discordDirectory.appendingPathComponent("discord-ipc-\(index)").path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard path.utf8.count < 104 else { continue }

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            Self.noSigPipe(fd)
            if Self.connectUnix(fd, to: path) {
                Self.log("connected to Discord at \(path)")
                return fd
            }
            close(fd)
        }
        return nil
    }

    /// Tells the app that Discord is not running, in the shape it expects from Discord itself.
    private func sendError(to client: Int32) {
        let payload: [String: Any] = [
            "cmd": "DISPATCH",
            "evt": "ERROR",
            "data": ["code": 4000, "message": Self.discordNotRunningMessage],
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return }
        Self.writeAll(client, DiscordIPCFrame.encode(DiscordIPCFrame.Frame(opcode: .frame, payload: json)))
    }

    // MARK: - Pumping

    /// Copies bytes one way until the source ends, then half-closes the destination.
    private static func pump(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let received = recv(source, &buffer, buffer.count, 0)
            if received <= 0 { break }
            let chunk = Data(buffer[0 ..< received])
            guard writeAll(destination, chunk) else { break }
        }
        shutdown(destination, SHUT_WR)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let written = send(fd, base.advanced(by: sent), raw.count - sent, 0)
                guard written > 0 else { return false }
                sent += written
            }
            return true
        }
    }

    // MARK: - Socket Helpers

    private static func bindLoopback(_ fd: Int32, port: UInt16) throws {
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw Failure.bind(String(cString: strerror(errno))) }
    }

    private static func boundPort(of fd: Int32) -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard result == 0 else { return 0 }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func connectUnix(_ fd: Int32, to path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                    _ = strncpy(buffer, source, capacity - 1)
                }
            }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    /// A relay that dies on `SIGPIPE` would take the whole helper down with one closed socket.
    private static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// A LaunchServices-launched app has no terminal, so the same message goes to both places: the
    /// system log is what `log show` can see when the helper misbehaves.
    static let logger = Logger(subsystem: "com.popcornfuzzy.Kaset.PresenceBridge", category: "Relay")

    public static func log(_ message: String) {
        FileHandle.standardError.write(Data("[presence-bridge] \(message)\n".utf8))
        Self.logger.notice("\(message, privacy: .public)")
    }
}
