import Foundation
import MicSystemKit
import Observation
import os

/// DJI Mic Mini 2S: up to four transmitters on one receiver, controlled over the receiver's
/// `com.dji.mic` channel with DJI's DUML protocol. On macOS that channel is a vendor USB
/// interface; on iOS it is an External Accessory protocol, which the app opens and passes in.
///
/// Commands are spaced out because the receiver briefly drops transmitter records when several
/// writes land within a few hundred milliseconds.
@Observable @MainActor
public final class DJIMicMini2S: MicSystem {
    public static let id = "dji-mic-mini-2s"
    public static let name = "DJI Mic Mini 2S"
    public static let transmitterCount = 4

    static let vendorID = 0x2CA3
    /// 0x4015 in mono and stereo mode, 0x4115 in 4-track mode.
    static let productIDs = [0x4015, 0x4115]
    /// The receiver's External Accessory protocol, for apps that pass an `ExternalAccessoryLink`.
    public static let accessoryProtocol = "com.dji.mic"

    public static func isReceiver(_ device: AudioDeviceDescription) -> Bool {
        device.isUSB(vendor: vendorID, products: productIDs)
    }

    private(set) var linked = false
    private(set) var status: ReceiverStatus?
    private(set) var identity: DeviceIdentity?
    private(set) var slots: [SlotInfo?] = [nil, nil, nil, nil]
    /// Gain values sent but not yet confirmed by a status push, per slot.
    private(set) var pendingGain: [Int?] = [nil, nil, nil, nil]
    private(set) var switchingMode = false

    struct SlotInfo: Equatable {
        var identity: DeviceIdentity?
        var status: TransmitterStatus?
    }

    @ObservationIgnored private let log = Logger(subsystem: "com.sauerdev.lavboard", category: "dji-mic-mini-2s")
    @ObservationIgnored private let link: (any ControlLink)?
    @ObservationIgnored private var parser = DUMLParser()
    @ObservationIgnored private var seq: UInt16 = 0x4000
    @ObservationIgnored private var queue: [(key: String, payload: [UInt8])] = []
    @ObservationIgnored private var pumping = false
    @ObservationIgnored private var pendingSince: [Date?] = [nil, nil, nil, nil]

    /// Uses the platform's own control link: the receiver's vendor USB interface on macOS. Elsewhere
    /// the module runs audio-only unless the app passes a link to `init(link:)`.
    public convenience init() {
        self.init(link: Self.platformLink())
    }

    /// `link` reaches the receiver's `com.dji.mic` channel. Pass nil to run audio-only: tracks,
    /// meters and mutes still work, but battery, gain, modes and settings stay hidden.
    public init(link: (any ControlLink)?) {
        self.link = link
    }

    private static func platformLink() -> (any ControlLink)? {
        #if os(macOS)
        USBBulkLink(USBBulkInterface(vendorID: vendorID, productIDs: productIDs, interfaceNumber: 4,
                                     alternateSetting: 1, inEndpoint: 0x84, outEndpoint: 0x04),
                    label: id)
        #else
        nil
        #endif
    }

    public func start() {
        guard let link else { return }
        link.onConnect = { _ in Task { @MainActor in self.didConnect() } }
        link.onDisconnect = { Task { @MainActor in self.didDisconnect() } }
        link.onBytes = { bytes in Task { @MainActor in self.receive(bytes) } }
        link.start()
    }

    // MARK: MicSystem

    public var isConnected: Bool { linked }

    public var transmitters: [TransmitterState] {
        (0..<Self.transmitterCount).map { slot in
            guard let tx = slots[slot]?.status else { return TransmitterState(serial: slots[slot]?.identity?.serial) }
            return TransmitterState(connected: true, battery: tx.batteryFraction, charging: tx.charging,
                                    gainDB: Double(tx.gainDB), pendingGainDB: pendingGain[slot].map(Double.init),
                                    recording: tx.recording, serial: slots[slot]?.identity?.serial)
        }
    }

    /// USB audio channel N carries slot N. In 4-track mode every transmitter has its own channel;
    /// in mono and stereo the receiver presents two channels of mixed audio, and the app shows a
    /// notice to switch.
    public func audioChannel(forSlot slot: Int) -> Int? {
        (0..<Self.transmitterCount).contains(slot) ? slot : nil
    }

    // Without a control link the module can't send anything, so it offers no controls at all.

    public var gain: GainCapability? { link == nil ? nil : GainCapability(range: -12...12, step: 1) }

    public func setGain(_ dB: Double, slot: Int) {
        guard (0..<Self.transmitterCount).contains(slot) else { return }
        let value = max(-12, min(12, Int(dB.rounded())))
        pendingGain[slot] = value
        pendingSince[slot] = Date()
        enqueue("gain.\(slot)", target: MicProtocol.slotMasks[slot], param: .gain, value: [UInt8(bitPattern: Int8(value))])
    }

    public var canRecordOnTransmitters: Bool { link != nil }

    /// Starts or stops the transmitters' internal 32-bit float recording on every connected slot.
    public func setTransmitterRecording(_ on: Bool) {
        if on {
            enqueue("time", target: MicProtocol.receiverTarget, param: .timeSync, value: MicProtocol.timeSyncValue())
        }
        for slot in 0..<Self.transmitterCount where slots[slot]?.status != nil {
            enqueue("rec.\(slot)", target: MicProtocol.slotMasks[slot], param: .record, value: [on ? 1 : 0])
        }
    }

    public var modes: [ReceiverMode] {
        link == nil ? [] : ChannelMode.allCases.map { ReceiverMode(id: $0.id, name: $0.label) }
    }
    public var currentModeID: String? { linked ? status?.mode.id : nil }
    public var isSwitchingMode: Bool { switchingMode }

    /// Switching to or from 4-track restarts the receiver; the link reconnects on its own.
    public func setMode(_ id: String) {
        guard let mode = ChannelMode(id: id), mode != status?.mode else { return }
        if mode == .quad || status?.mode == .quad { switchingMode = true }
        enqueue("mode", target: MicProtocol.receiverTarget, param: .channelMode, value: [mode.rawValue])
    }

    public func modeSwitchWarning(to id: String) -> String? {
        guard ChannelMode(id: id) == .quad || status?.mode == .quad else { return nil }
        return "Switching to or from 4-track restarts the receiver. Audio drops out for a few seconds."
    }

    public var settings: [MicSetting] {
        guard link != nil else { return [] }
        let first = slots.compactMap { $0?.status }.first
        return [
            MicSetting(id: "noise", title: "Noise cancellation",
                       kind: .choice(NoiseCancellation.allCases.map { ($0.rawValue, $0.label) }),
                       value: first.map { .choice($0.noise.rawValue) }),
            MicSetting(id: "lowCut", title: "Low cut", kind: .toggle, value: first.map { .toggle($0.lowCut) }),
        ]
    }

    public var settingsNote: String? {
        guard link != nil else { return nil }
        return slots.contains { $0?.status != nil } ? "Applies to every connected mic." : "Switch on a mic to change these."
    }

    public func set(_ settingID: String, to value: MicSettingValue) {
        switch (settingID, value) {
        case ("noise", .choice(let raw)):
            guard let nc = NoiseCancellation(rawValue: raw) else { return }
            enqueue("nc.on", target: MicProtocol.allTransmitters, param: .noiseCancellation, value: [nc == .off ? 0 : 1])
            if nc != .off {
                enqueue("nc.strong", target: MicProtocol.allTransmitters, param: .noiseStrong, value: [nc == .strong ? 1 : 0])
            }
        case ("lowCut", .toggle(let on)):
            enqueue("lowcut", target: MicProtocol.allTransmitters, param: .lowCut, value: [on ? 1 : 0])
        default:
            break
        }
    }

    public var notice: MicNotice? {
        guard linked, !switchingMode, let mode = status?.mode, mode != .quad else { return nil }
        return MicNotice(message: "The receiver is in \(mode.label) mode, so all mics arrive mixed together. Switch to 4-track to control each mic.",
                         actionTitle: "Switch to 4-track", modeID: ChannelMode.quad.id)
    }

    // MARK: Commands

    private func enqueue(_ key: String, target: UInt32, param: MicProtocol.Param, value: [UInt8]) {
        let payload = MicProtocol.setParamPayload(target: target, param: param, value: value)
        if let i = queue.firstIndex(where: { $0.key == key }) {
            queue[i].payload = payload
        } else {
            queue.append((key, payload))
        }
        pump()
    }

    private func pump() {
        guard !pumping, linked, !queue.isEmpty else { return }
        pumping = true
        let next = queue.removeFirst()
        seq &+= 1
        let frame = DUMLFrame(sender: MicProtocol.host, receiver: MicProtocol.receiverAddress, seq: seq,
                              type: 0x40, cmdSet: MicProtocol.cmdSet, cmdID: MicProtocol.cmdSetParam, payload: next.payload)
        link?.send(frame.encoded())
        log.info("sent \(next.key, privacy: .public)")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            self.pumping = false
            self.pump()
        }
    }

    // MARK: Incoming

    private func didConnect() {
        linked = true
        switchingMode = false
        parser = DUMLParser()
        pump()
    }

    private func didDisconnect() {
        linked = false
        status = nil
        slots = [nil, nil, nil, nil]
        pendingGain = [nil, nil, nil, nil]
    }

    /// Bytes from the vendor interface. Internal so tests can feed captured traffic.
    func receive(_ bytes: [UInt8]) {
        for frame in parser.feed(bytes) where frame.cmdSet == MicProtocol.cmdSet {
            if frame.isResponse {
                if frame.payload.first != 0x00 {
                    log.error("command rejected: \(frame.payload.map { String(format: "%02x", $0) }.joined(), privacy: .public)")
                }
            } else if frame.cmdID == MicProtocol.cmdStatus {
                apply(MicRecord.parse(payload: frame.payload))
            }
        }
    }

    private func apply(_ records: [MicRecord]) {
        guard let first = records.first else { return }
        switch first.field {
        case 0x03:
            applyStatus(records)
        case 0x01:
            applyIdentity(records)
        default:
            break
        }
    }

    private func applyStatus(_ records: [MicRecord]) {
        var next: [SlotInfo?] = [nil, nil, nil, nil]
        for record in records {
            if record.field == 0x03, record.device == 0 {
                status = ReceiverStatus(value: record.value)
            } else if record.field == 0x02, let slot = MicProtocol.slotMasks.firstIndex(of: record.device) {
                next[slot] = SlotInfo(identity: slots[slot]?.identity, status: TransmitterStatus(value: record.value))
            }
        }
        for slot in 0..<Self.transmitterCount {
            if let wanted = pendingGain[slot] {
                let confirmed = next[slot]?.status?.gainDB == wanted
                let expired = (pendingSince[slot].map { Date().timeIntervalSince($0) } ?? 0) > 2.5
                if confirmed || expired {
                    if expired && !confirmed { log.error("gain for slot \(slot + 1) not confirmed") }
                    pendingGain[slot] = nil
                }
            }
        }
        if next != slots { slots = next }
    }

    private func applyIdentity(_ records: [MicRecord]) {
        var fields: [UInt32: (fw: String, serial: String, name: String)] = [:]
        for record in records {
            var entry = fields[record.device] ?? ("", "", "")
            switch record.field {
            case 0x01 where record.value.count >= 18:
                entry.fw = record.value[0..<4].reversed().map { String(format: "%02d", $0) }.joined(separator: ".")
                entry.serial = String(decoding: record.value[4..<18], as: UTF8.self)
            case 0x06:
                entry.name = String(decoding: record.value, as: UTF8.self)
            default:
                break
            }
            fields[record.device] = entry
        }
        for (device, f) in fields {
            let id = DeviceIdentity(firmware: f.fw, serial: f.serial, name: f.name)
            if device == 0 {
                if identity != id { identity = id }
            } else if let slot = MicProtocol.slotMasks.firstIndex(of: device), slots[slot]?.identity != id {
                var info = slots[slot] ?? SlotInfo()
                info.identity = id
                slots[slot] = info
            }
        }
    }
}

extension ChannelMode {
    var id: String {
        switch self {
        case .mono: "mono"
        case .stereo: "stereo"
        case .quad: "quad"
        }
    }

    init?(id: String) {
        guard let mode = ChannelMode.allCases.first(where: { $0.id == id }) else { return nil }
        self = mode
    }
}

extension TransmitterStatus {
    /// The receiver's 1 (full) ... 7 (empty) gauge as a fraction.
    var batteryFraction: Double? {
        (1...7).contains(batteryLevel) ? Double(7 - batteryLevel) / 6 : nil
    }
}
