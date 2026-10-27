import DiscordBridge
import Foundation
import Testing
@testable import Kaset

// MARK: - DiscordIPCTests

@Suite(.serialized, .tags(.service))
struct DiscordIPCTests {
    // MARK: - Framing

    @Test("A frame is an opcode and a length, both little-endian, then the payload")
    func frameEncoding() {
        let data = DiscordIPCFrame.encode(DiscordIPCFrame.Frame(opcode: .frame, payload: Data("hi".utf8)))

        #expect([UInt8](data) == [1, 0, 0, 0, 2, 0, 0, 0, 0x68, 0x69])
    }

    @Test("Reading a buffer yields whole frames and keeps the partial one")
    func drainLeavesPartialFrame() {
        var buffer = DiscordIPCFrame.encode(DiscordIPCFrame.Frame(opcode: .frame, payload: Data("one".utf8)))
        buffer.append(DiscordIPCFrame.encode(DiscordIPCFrame.Frame(opcode: .frame, payload: Data("two".utf8))))
        buffer.append(contentsOf: [1, 0, 0, 0, 10, 0, 0, 0, 0x74]) // header says 10 bytes, one present

        var drained = DiscordIPCFrame.drain(from: &buffer)
        #expect(drained.count == 2)
        #expect(String(decoding: drained[0].payload, as: UTF8.self) == "one")
        #expect(String(decoding: drained[1].payload, as: UTF8.self) == "two")
        #expect(buffer.count == 9)

        drained = DiscordIPCFrame.drain(from: &buffer)
        #expect(drained.isEmpty)
    }

    @Test("An empty buffer yields nothing")
    func drainEmptyBuffer() {
        var buffer = Data()
        #expect(DiscordIPCFrame.drain(from: &buffer).isEmpty)
    }

    // MARK: - Request Encoding

    @Test("A set-activity request names the command, the pid and the activity")
    func requestEncodesActivity() throws {
        let activity = try #require(
            DiscordActivity.nowPlaying(
                song: Song(
                    id: "video123",
                    title: "Blinding Lights",
                    artists: [Artist(id: "UC1", name: "The Weeknd")],
                    duration: 200,
                    thumbnailURL: nil,
                    videoId: "video123"
                ),
                duration: 200,
                isPlaying: true,
                startedAt: Date(timeIntervalSince1970: 1_000)
            )
        )

        let data = try JSONEncoder().encode(DiscordIPCRequest(activity: activity, nonce: "nonce-1", pid: 42))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let args = try #require(json["args"] as? [String: Any])
        let encodedActivity = try #require(args["activity"] as? [String: Any])
        let assets = try #require(encodedActivity["assets"] as? [String: Any])
        let timestamps = try #require(encodedActivity["timestamps"] as? [String: Any])

        #expect(json["cmd"] as? String == "SET_ACTIVITY")
        #expect(json["nonce"] as? String == "nonce-1")
        #expect(args["pid"] as? Int == 42)
        #expect(encodedActivity["type"] as? Int == 2)
        #expect(encodedActivity["details"] as? String == "Blinding Lights")
        #expect(encodedActivity["state"] as? String == "The Weeknd")
        #expect(timestamps["start"] as? Int == 1_000_000)
        #expect(timestamps["end"] as? Int == 1_200_000)
        #expect(assets["large_text"] == nil)
    }

    @Test("Clearing a card sends a null activity rather than leaving the key out")
    func requestEncodesNullActivity() throws {
        let data = try JSONEncoder().encode(DiscordIPCRequest(activity: nil, nonce: "nonce-2", pid: 42))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let args = try #require(json["args"] as? [String: Any])

        #expect(args["activity"] is NSNull)
    }

    // MARK: - Connection

    @Test("Connecting where no Discord socket exists reports that Discord is not running")
    func connectWithoutSocket() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dipc-empty-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let connection = DiscordIPCConnection()
        await #expect(throws: DiscordIPCConnection.Failure.discordNotRunning) {
            try await connection.connect(
                applicationID: "123456789012345678",
                endpoint: .unixSocket(directory: directory)
            )
        }
    }

    @Test("The connection handshakes and sets an activity over a real socket")
    func handshakeAndSetActivity() async throws {
        let server = try FakeDiscordSocketServer()
        defer { server.stop() }
        let serving = Task.detached { server.run() }

        let connection = DiscordIPCConnection()
        try await connection.connect(
            applicationID: "123456789012345678",
            endpoint: .unixSocket(directory: server.directory)
        )

        let request = DiscordIPCRequest(activity: nil, nonce: "nonce-3", pid: 42)
        let reply = try await connection.perform(
            command: try JSONEncoder().encode(request),
            nonce: "nonce-3",
            timeout: .seconds(3)
        )

        #expect(String(decoding: reply, as: UTF8.self).contains("nonce-3"))
        #expect(server.receivedClientID == "123456789012345678")
        #expect(server.receivedCommands == ["SET_ACTIVITY"])

        await connection.close()
        serving.cancel()
    }
}
