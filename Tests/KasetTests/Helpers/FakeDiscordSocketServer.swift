import Darwin
import DiscordBridge
import Foundation
@testable import Kaset

// MARK: - FakeDiscordSocketServer

/// A stand-in for the Discord client's IPC socket: it answers the handshake and echoes each
/// command's nonce, so the transports can be exercised without Discord installed.
///
/// Used both by the app's own connection tests and by the presence helper's relay tests.
final class FakeDiscordSocketServer: @unchecked Sendable {
    let directory: URL

    private let listenFD: Int32
    private let lock = NSLock()
    private var clientID: String?
    private var commands: [String] = []

    var receivedClientID: String? {
        self.lock.withLock { self.clientID }
    }

    var receivedCommands: [String] {
        self.lock.withLock { self.commands }
    }

    init() throws {
        // A unix socket path must fit in `sun_path` (104 bytes), so the directory stays short.
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dipc-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)

        self.listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard self.listenFD >= 0 else {
            throw DiscordIPCConnection.Failure.connectionFailed("socket() failed: \(errno)")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = self.directory.appendingPathComponent("discord-ipc-0").path
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            close(self.listenFD)
            throw DiscordIPCConnection.Failure.connectionFailed("socket path is too long: \(path)")
        }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                    _ = strncpy(buffer, source, capacity - 1)
                }
            }
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(self.listenFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(self.listenFD)
            throw DiscordIPCConnection.Failure.connectionFailed("bind() failed: \(errno)")
        }
        guard listen(self.listenFD, 4) == 0 else {
            close(self.listenFD)
            throw DiscordIPCConnection.Failure.connectionFailed("listen() failed: \(errno)")
        }
    }

    func stop() {
        close(self.listenFD)
        try? FileManager.default.removeItem(at: self.directory)
    }

    /// Accepts one client and serves it until it disconnects.
    func run() {
        let clientFD = accept(self.listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        defer { close(clientFD) }

        while let frame = self.readFrame(clientFD) {
            switch frame.opcode {
            case 0:
                let json = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any]
                self.lock.withLock { self.clientID = json?["client_id"] as? String }
                self.write(clientFD, opcode: 1, json: [
                    "cmd": "DISPATCH",
                    "evt": "READY",
                    "data": ["v": 1],
                ])
            case 1:
                let json = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any]
                let command = json?["cmd"] as? String ?? ""
                let nonce = json?["nonce"] as? String
                self.lock.withLock { self.commands.append(command) }
                self.write(clientFD, opcode: 1, json: [
                    "cmd": command,
                    "data": [:],
                    "nonce": nonce ?? "",
                ])
            case 3:
                self.write(clientFD, opcode: 4, payload: frame.payload)
            default:
                break
            }
        }
    }

    // MARK: - Wire

    private struct InboundFrame {
        let opcode: UInt32
        let payload: Data
    }

    private func readFrame(_ fd: Int32) -> InboundFrame? {
        guard let header = self.read(fd, count: DiscordIPCFrame.headerLength) else { return nil }
        let bytes = [UInt8](header)
        let opcode = bytes[0 ..< 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        let length = bytes[4 ..< 8].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        guard let payload = self.read(fd, count: Int(length)) else { return nil }
        return InboundFrame(opcode: opcode, payload: payload)
    }

    private func read(_ fd: Int32, count: Int) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: max(count, 1))
        while data.count < count {
            let received = recv(fd, &chunk, count - data.count, 0)
            guard received > 0 else { return nil }
            data.append(contentsOf: chunk[0 ..< received])
        }
        return data
    }

    private func write(_ fd: Int32, opcode: UInt32, json: [String: Any]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: json) else { return }
        self.write(fd, opcode: opcode, payload: payload)
    }

    private func write(_ fd: Int32, opcode: UInt32, payload: Data) {
        let data = DiscordIPCFrame.encode(DiscordIPCFrame.Frame(opcode: opcode, payload: payload))
        _ = data.withUnsafeBytes { buffer in
            send(fd, buffer.baseAddress, buffer.count, 0)
        }
    }
}
