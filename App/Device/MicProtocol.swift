import Foundation

/// Command set 0x5B of the DJI Mic Mini 2S receiver. Offsets follow usokawa/dji-mic-mo
/// and were verified against a live receiver with four Mini 2S transmitters.
enum MicProtocol {
    static let host: UInt8 = 0x02
    static let receiverAddress: UInt8 = 0x5A
    static let cmdSet: UInt8 = 0x5B
    static let cmdSetParam: UInt8 = 0x01
    static let cmdStatus: UInt8 = 0x03

    /// Transmitter slots are addressed as a bitmask; USB audio channel N carries slot N.
    static let slotMasks: [UInt32] = [0x01, 0x02, 0x04, 0x08]
    static let receiverTarget: UInt32 = 0x0000
    static let allTransmitters: UInt32 = 0xFFFF

    /// Parameter ids. Destructive ones (0x07 format, 0x23 plug-free speaker reboot) are deliberately absent.
    enum Param: UInt16 {
        case channelMode = 0x08       // receiver: 0 mono, 2 stereo, 4 quad (restarts the receiver)
        case gain = 0x39              // transmitter: -12...+12 dB
        case noiseCancellation = 0x38 // all transmitters: 0 off, 1 on
        case noiseStrong = 0x37       // all transmitters: 0 basic, 1 strong
        case lowCut = 0x03            // all transmitters
        case record = 0x02            // transmitter internal recording
        case timeSync = 0x33          // clock for transmitter recordings
    }

    static func setParamPayload(target: UInt32, param: Param, value: [UInt8]) -> [UInt8] {
        var p: [UInt8] = [0x02]
        p += withUnsafeBytes(of: target.littleEndian, Array.init)
        p += withUnsafeBytes(of: param.rawValue.littleEndian, Array.init)
        p.append(UInt8(value.count))
        p += value
        return p
    }

    static func timeSyncValue(_ date: Date = Date()) -> [UInt8] {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return [0x09, UInt8((c.year ?? 2000) % 100), UInt8(c.month ?? 1), UInt8(c.day ?? 1),
                UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0), 0x00]
    }
}

/// One `[field][u32 device][len][value]` record from a status push.
struct MicRecord: Equatable {
    var field: UInt8
    var device: UInt32
    var value: [UInt8]

    /// Status push payload: `[0x03][u16 body length]` followed by records.
    static func parse(payload: [UInt8]) -> [MicRecord] {
        guard payload.count >= 3 else { return [] }
        let bodyLength = Int(payload[1]) | (Int(payload[2]) << 8)
        let body = Array(payload.dropFirst(3).prefix(bodyLength))
        var records: [MicRecord] = []
        var i = 0
        while i + 6 <= body.count {
            let device = UInt32(body[i + 1]) | UInt32(body[i + 2]) << 8 | UInt32(body[i + 3]) << 16 | UInt32(body[i + 4]) << 24
            let length = Int(body[i + 5])
            guard i + 6 + length <= body.count else { break }
            records.append(MicRecord(field: body[i], device: device, value: Array(body[(i + 6)..<(i + 6 + length)])))
            i += 6 + length
        }
        return records
    }
}

enum ChannelMode: UInt8, CaseIterable {
    case mono = 0, stereo = 2, quad = 4

    var label: String {
        switch self {
        case .mono: "Mono"
        case .stereo: "Stereo"
        case .quad: "4-track"
        }
    }
}

struct ReceiverStatus: Equatable {
    var mode: ChannelMode
    var batteryLevel: Int      // 1 = full ... 7 = empty
    var charging: Bool
    var connectedMask: UInt8

    init?(value v: [UInt8]) {
        guard v.count >= 25 else { return nil }
        mode = v[1] & 0x08 != 0 ? .quad : (v[1] & 0x04 != 0 ? .stereo : .mono)
        batteryLevel = Int((v[1] >> 5) & 0x07)
        charging = v[1] & 0x10 != 0
        connectedMask = v[24]
    }
}

enum NoiseCancellation: String, CaseIterable, Identifiable {
    case off, basic, strong
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct TransmitterStatus: Equatable {
    var batteryLevel: Int      // 1 = full ... 7 = empty
    var charging: Bool
    var gainDB: Int
    var noise: NoiseCancellation
    var lowCut: Bool
    var recording: Bool
    var recordingHoursLeft: Double

    init?(value v: [UInt8]) {
        guard v.count >= 12 else { return nil }
        batteryLevel = Int((v[1] >> 2) & 0x07)
        charging = v[1] & 0x02 != 0
        gainDB = Int(Int8(bitPattern: v[7]))
        noise = v[1] & 0x01 == 0 ? .off : (v[0] & 0x20 != 0 ? .strong : .basic)
        lowCut = v[3] & 0x20 != 0
        recording = v[3] & 0x10 != 0
        recordingHoursLeft = Double(UInt16(v[10]) | UInt16(v[11]) << 8) / 10
    }
}

struct DeviceIdentity: Equatable {
    var firmware: String
    var serial: String
    var name: String
}

extension Int {
    /// Battery gauge 1 (full) ... 7 (empty) to a rough percentage.
    var batteryPercent: Int { self >= 1 && self <= 7 ? (7 - self) * 100 / 6 : 0 }
}
