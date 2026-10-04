import Foundation

/// DJI DUML v1 framing: 0x55, 10-bit length + version, CRC8 header, addressing,
/// sequence, command type/set/id, payload, CRC16 trailer.
enum DUML {
    private static let crc8Table: [UInt8] = (0..<256).map { i in
        var c = UInt8(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x8C : c >> 1 }
        return c
    }

    private static let crc16Table: [UInt16] = (0..<256).map { i in
        var c = UInt16(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x8408 : c >> 1 }
        return c
    }

    static func crc8<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        var c: UInt8 = 0x77
        for b in bytes { c = crc8Table[Int(c ^ b)] }
        return c
    }

    static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var c: UInt16 = 0x3692
        for b in bytes { c = (c >> 8) ^ crc16Table[Int((c ^ UInt16(b)) & 0xFF)] }
        return c
    }
}

struct DUMLFrame: Equatable {
    var sender: UInt8
    var receiver: UInt8
    var seq: UInt16
    var type: UInt8
    var cmdSet: UInt8
    var cmdID: UInt8
    var payload: [UInt8]

    var isResponse: Bool { type & 0x80 != 0 }

    func encoded() -> [UInt8] {
        let length = 13 + payload.count
        var out: [UInt8] = [0x55, UInt8(length & 0xFF), UInt8((length >> 8) & 0x03) | 0x04]
        out.append(DUML.crc8(out))
        out += [sender, receiver, UInt8(seq & 0xFF), UInt8(seq >> 8), type, cmdSet, cmdID]
        out += payload
        let crc = DUML.crc16(out)
        out += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        return out
    }

    /// Decodes one complete frame; returns nil if the bytes are not a valid frame.
    init?(bytes: [UInt8]) {
        guard bytes.count >= 13, bytes[0] == 0x55 else { return nil }
        let length = Int(bytes[1]) | (Int(bytes[2] & 0x03) << 8)
        guard length >= 13, length <= bytes.count, DUML.crc8(bytes[0..<3]) == bytes[3] else { return nil }
        let crc = UInt16(bytes[length - 2]) | (UInt16(bytes[length - 1]) << 8)
        guard DUML.crc16(bytes[0..<(length - 2)]) == crc else { return nil }
        self.init(sender: bytes[4], receiver: bytes[5], seq: UInt16(bytes[6]) | (UInt16(bytes[7]) << 8),
                  type: bytes[8], cmdSet: bytes[9], cmdID: bytes[10], payload: Array(bytes[11..<(length - 2)]))
    }

    init(sender: UInt8, receiver: UInt8, seq: UInt16, type: UInt8, cmdSet: UInt8, cmdID: UInt8, payload: [UInt8]) {
        self.sender = sender
        self.receiver = receiver
        self.seq = seq
        self.type = type
        self.cmdSet = cmdSet
        self.cmdID = cmdID
        self.payload = payload
    }
}

/// Reassembles DUML frames from an arbitrary byte stream (USB transfers split and join frames).
struct DUMLParser {
    private var buffer: [UInt8] = []

    mutating func feed(_ bytes: [UInt8]) -> [DUMLFrame] {
        buffer += bytes
        var frames: [DUMLFrame] = []
        var start = 0
        while start < buffer.count {
            guard let sync = buffer[start...].firstIndex(of: 0x55) else {
                start = buffer.count
                break
            }
            start = sync
            if buffer.count - start < 4 { break }
            let header = buffer[start..<(start + 3)]
            let length = Int(buffer[start + 1]) | (Int(buffer[start + 2] & 0x03) << 8)
            if DUML.crc8(header) != buffer[start + 3] || length < 13 {
                start += 1
                continue
            }
            if buffer.count - start < length { break }
            if let frame = DUMLFrame(bytes: Array(buffer[start..<(start + length)])) {
                frames.append(frame)
                start += length
            } else {
                start += 1
            }
        }
        buffer.removeFirst(start)
        return frames
    }
}
