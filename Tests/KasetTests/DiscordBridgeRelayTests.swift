import DiscordBridge
import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
struct DiscordBridgeRelayTests {
    // MARK: - Helpers

    private func makeEmptyDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Relaying

    @Test("The helper relays the app's frames to Discord and the answers back")
    func relaysToDiscord() async throws {
        let discord = try FakeDiscordSocketServer()
        defer { discord.stop() }
        let serving = Task.detached { discord.run() }

        let relay = BridgeRelay(discordDirectory: discord.directory)
        try relay.start()
        defer { relay.stop() }

        let port = relay.boundPort
        #expect(port != 0)

        let connection = DiscordIPCConnection()
        try await connection.connect(
            applicationID: "123456789012345678",
            endpoint: .bridge(port: port)
        )

        let request = DiscordIPCRequest(activity: nil, nonce: "nonce-relay", pid: 42)
        let reply = try await connection.perform(
            command: try JSONEncoder().encode(request),
            nonce: "nonce-relay",
            timeout: .seconds(3)
        )

        #expect(String(decoding: reply, as: UTF8.self).contains("nonce-relay"))
        #expect(discord.receivedClientID == "123456789012345678")
        #expect(discord.receivedCommands == ["SET_ACTIVITY"])

        await connection.close()
        serving.cancel()
    }

    @Test("The helper tells the app when the Discord client is not running")
    func reportsMissingDiscord() async throws {
        let noDiscord = try self.makeEmptyDirectory("dipc-nodiscord")
        defer { try? FileManager.default.removeItem(at: noDiscord) }

        let relay = BridgeRelay(discordDirectory: noDiscord)
        try relay.start()
        defer { relay.stop() }

        let connection = DiscordIPCConnection()

        do {
            try await connection.connect(
                applicationID: "123456789012345678",
                endpoint: .bridge(port: relay.boundPort)
            )
            Issue.record("expected the helper to refuse the handshake")
        } catch let failure as DiscordIPCConnection.Failure {
            #expect(failure == .rejected(BridgeRelay.discordNotRunningMessage))
        }
    }

    @Test("The helper counts connected clients, which is how it notices Kaset is gone")
    func tracksConnectedClients() async throws {
        let discord = try FakeDiscordSocketServer()
        defer { discord.stop() }
        let serving = Task.detached { discord.run() }

        let relay = BridgeRelay(discordDirectory: discord.directory)
        try relay.start()
        defer { relay.stop() }

        #expect(relay.connectedClients == 0)

        let connection = DiscordIPCConnection()
        try await connection.connect(
            applicationID: "123456789012345678",
            endpoint: .bridge(port: relay.boundPort)
        )

        #expect(try await self.waitForClients(relay, toBe: 1))

        await connection.close()

        #expect(try await self.waitForClients(relay, toBe: 0))
        serving.cancel()
    }

    /// Polls until the relay's client count settles, because it changes on the relay's own threads.
    private func waitForClients(
        _ relay: BridgeRelay,
        toBe expected: Int,
        attempts: Int = 100
    ) async throws -> Bool {
        for _ in 0 ..< attempts {
            if relay.connectedClients == expected { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return relay.connectedClients == expected
    }

    @Test("A stopped helper stops accepting connections")
    func stopClosesListener() async throws {
        let emptyDiscord = try self.makeEmptyDirectory("dipc-stale")
        defer { try? FileManager.default.removeItem(at: emptyDiscord) }

        let relay = BridgeRelay(discordDirectory: emptyDiscord)
        try relay.start()
        let port = relay.boundPort
        #expect(port != 0)

        relay.stop()

        let connection = DiscordIPCConnection()
        do {
            try await connection.connect(
                applicationID: "123456789012345678",
                endpoint: .bridge(port: port)
            )
            Issue.record("expected the stopped helper to refuse the connection")
        } catch is DiscordIPCConnection.Failure {
            // Refused, which is the point.
        }
    }

    @Test("A port another helper already holds is refused, so a second copy can step to the next one")
    func refusesATakenPort() throws {
        let emptyDiscord = try self.makeEmptyDirectory("dipc-port")
        defer { try? FileManager.default.removeItem(at: emptyDiscord) }

        let first = BridgeRelay(discordDirectory: emptyDiscord)
        try first.start()
        defer { first.stop() }

        let second = BridgeRelay(discordDirectory: emptyDiscord, port: first.boundPort)
        #expect(throws: BridgeRelay.Failure.self) {
            try second.start()
        }
    }
}
