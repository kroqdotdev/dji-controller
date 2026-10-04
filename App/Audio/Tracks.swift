import Foundation

/// Where a track's audio comes from.
enum TrackSource: Codable, Hashable {
    /// A DJI transmitter slot on the receiver (0-3, shown as TX1-TX4).
    case transmitter(slot: Int)
    /// A channel (or a stereo pair starting at `channel`) on any input device. `name` is cached
    /// so the strip can still say what is missing when the device is unplugged.
    case device(uid: String, name: String, channel: Int, stereo: Bool)

    var isStereo: Bool {
        if case .device(_, _, _, let stereo) = self { return stereo }
        return false
    }

    var transmitterSlot: Int? {
        if case .transmitter(let slot) = self { return slot }
        return nil
    }

    /// Identifies the physical input, ignoring the cached device name.
    var identity: String {
        switch self {
        case .transmitter(let slot): "tx\(slot)"
        case .device(let uid, _, let channel, let stereo): "\(uid)#\(channel)#\(stereo)"
        }
    }

    /// Short description for the strip, e.g. "TX2" or "In 3+4".
    var channelLabel: String {
        switch self {
        case .transmitter(let slot):
            "TX\(slot + 1)"
        case .device(_, _, let channel, let stereo):
            stereo ? "In \(channel + 1)+\(channel + 2)" : "In \(channel + 1)"
        }
    }
}

struct Track: Codable, Identifiable, Equatable {
    static let maximum = 8

    var id = UUID()
    var name: String
    var color: TapeColor = .white
    var faderDB: Double = 0
    var sendToVenue = true
    /// -1 (left) ... 1 (right); stereo tracks only.
    var balance: Double = 0
    var source: TrackSource

    init(name: String, color: TapeColor = .white, faderDB: Double = 0, sendToVenue: Bool = true,
         balance: Double = 0, source: TrackSource) {
        self.name = name
        self.color = color
        self.faderDB = faderDB
        self.sendToVenue = sendToVenue
        self.balance = balance
        self.source = source
    }

    /// Tolerates settings saved by older versions that lack newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(TapeColor.self, forKey: .color) ?? .white
        faderDB = try c.decodeIfPresent(Double.self, forKey: .faderDB) ?? 0
        sendToVenue = try c.decodeIfPresent(Bool.self, forKey: .sendToVenue) ?? true
        balance = try c.decodeIfPresent(Double.self, forKey: .balance) ?? 0
        source = try c.decode(TrackSource.self, forKey: .source)
    }

    /// A short tape-friendly default name: drops filler words ("Microphone", "USB", "Audio"),
    /// keeps two words, and adds the input number when a device has several inputs.
    static func defaultName(deviceName: String, channel: Int, stereo: Bool, deviceChannels: Int) -> String {
        let filler: Set<String> = ["microphone", "mic", "audio", "usb", "usb2.0", "usb-c", "2.0", "input", "stream", "webcam", "device"]
        let words = deviceName.split(separator: " ").map(String.init).filter { !filler.contains($0.lowercased()) }
        var name = words.prefix(2).joined(separator: " ")
        if name.isEmpty { name = deviceName.split(separator: " ").first.map(String.init) ?? "Input" }
        if stereo, deviceChannels > 2 {
            name += " \(channel + 1)+\(channel + 2)"
        } else if !stereo, deviceChannels > 1 {
            name += " \(channel + 1)"
        }
        return name
    }

    static func defaultSet() -> [Track] {
        (0..<4).map { Track(name: "Mic \($0 + 1)", source: .transmitter(slot: $0)) }
    }
}

/// Settings saved by versions that only had the four DJI strips.
struct LegacyStripSettings: Decodable {
    var name: String
    var color: TapeColor?
    var faderDB: Double?
    var sendToVenue: Bool?

    static func migrate(_ strips: [LegacyStripSettings]) -> [Track] {
        strips.prefix(4).enumerated().map { slot, strip in
            Track(name: strip.name, color: strip.color ?? .white, faderDB: strip.faderDB ?? 0,
                  sendToVenue: strip.sendToVenue ?? true, source: .transmitter(slot: slot))
        }
    }
}

/// Pure mapping from device channels to positions in the aggregate device's buffer lists.
/// The aggregate concatenates each sub-device's streams in sub-device order.
enum BufferMap {
    struct SubDevice: Equatable {
        var uid: String
        /// Channels per input stream, in order.
        var inputStreams: [Int]
        /// Channels per output stream, in order.
        var outputStreams: [Int]
    }

    /// Buffer index and channel within that buffer for `channel` of device `uid`.
    static func input(channel: Int, of uid: String, in subDevices: [SubDevice]) -> (buffer: Int, channel: Int)? {
        guard channel >= 0 else { return nil }
        var buffer = 0
        for device in subDevices {
            if device.uid == uid {
                var remaining = channel
                for (offset, channels) in device.inputStreams.enumerated() {
                    if remaining < channels { return (buffer + offset, remaining) }
                    remaining -= channels
                }
                return nil
            }
            buffer += device.inputStreams.count
        }
        return nil
    }

    /// Index of the first output buffer belonging to device `uid`.
    static func firstOutput(of uid: String, in subDevices: [SubDevice]) -> Int? {
        var buffer = 0
        for device in subDevices {
            if device.uid == uid { return device.outputStreams.isEmpty ? nil : buffer }
            buffer += device.outputStreams.count
        }
        return nil
    }
}
