import Foundation

// MARK: - DiscordIPCFrame

/// The framing of Discord's local IPC protocol: a little-endian opcode, a little-endian payload
/// length, then that many bytes of UTF-8 JSON.
///
/// Shared with the presence helper, which relays these frames without reading most of them.
/// Kept apart from any socket so the encoding can be checked byte for byte without a connection.
public enum DiscordIPCFrame {
    /// Protocol opcodes. Kaset only ever sends `handshake`, `frame` (a command) and `pong`.
    public enum Opcode: UInt32, Sendable {
        case handshake = 0
        case frame = 1
        case close = 2
        case ping = 3
        case pong = 4
    }

    public struct Frame: Equatable, Sendable {
        public let opcode: UInt32
        public let payload: Data

        public init(opcode: Opcode, payload: Data) {
            self.opcode = opcode.rawValue
            self.payload = payload
        }

        public init(opcode: UInt32, payload: Data) {
            self.opcode = opcode
            self.payload = payload
        }
    }

    /// Two 32-bit header fields.
    public static let headerLength = 8

    public static func encode(_ frame: Frame) -> Data {
        var data = Data(capacity: headerLength + frame.payload.count)
        data.append(contentsOf: littleEndianBytes(frame.opcode))
        data.append(contentsOf: littleEndianBytes(UInt32(frame.payload.count)))
        data.append(frame.payload)
        return data
    }

    /// Removes and returns every complete frame in `buffer`, leaving a partial frame behind for the
    /// next read.
    public static func drain(from buffer: inout Data) -> [Frame] {
        var frames: [Frame] = []

        while buffer.count >= headerLength {
            // `removeFirst` leaves `Data`'s start index where it was, so offsets are taken from it
            // rather than from zero.
            let start = buffer.startIndex
            let header = [UInt8](buffer[start ..< start + headerLength])
            let opcode = decodeUInt32(header[0 ..< 4])
            let length = Int(decodeUInt32(header[4 ..< 8]))
            let total = headerLength + length
            guard buffer.count >= total else { break }

            let payload = Data(buffer[(start + headerLength) ..< (start + total)])
            frames.append(Frame(opcode: opcode, payload: payload))
            buffer.removeFirst(total)
        }

        return frames
    }

    private static func littleEndianBytes(_ value: UInt32) -> [UInt8] {
        let little = value.littleEndian
        return [
            UInt8(truncatingIfNeeded: little),
            UInt8(truncatingIfNeeded: little >> 8),
            UInt8(truncatingIfNeeded: little >> 16),
            UInt8(truncatingIfNeeded: little >> 24),
        ]
    }

    private static func decodeUInt32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var value: UInt32 = 0
        for (offset, byte) in bytes.enumerated() {
            value |= UInt32(byte) << (8 * UInt32(offset))
        }
        return value
    }
}
