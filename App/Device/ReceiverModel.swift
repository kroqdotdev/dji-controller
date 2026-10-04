import Foundation
import Observation
import os

struct TransmitterInfo: Equatable {
    var identity: DeviceIdentity?
    var status: TransmitterStatus?
}

/// Live state of the receiver and its four transmitter slots, plus paced commands.
/// Commands are spaced out because the receiver briefly drops transmitter records
/// when several writes land within a few hundred milliseconds.
@Observable @MainActor
final class ReceiverModel {
    private(set) var connected = false
    private(set) var productID: Int?
    private(set) var status: ReceiverStatus?
    private(set) var identity: DeviceIdentity?
    private(set) var transmitters: [TransmitterInfo?] = [nil, nil, nil, nil]
    /// Gain values sent but not yet confirmed by a status push, per slot.
    private(set) var pendingGain: [Int?] = [nil, nil, nil, nil]
    private(set) var switchingMode = false

    var mode: ChannelMode? { status?.mode }
    var connectedCount: Int { transmitters.compactMap { $0?.status }.count }

    private let log = Logger(subsystem: "com.sauerdev.lavboard", category: "receiver")
    private let link = USBLink()
    private var parser = DUMLParser()
    private var seq: UInt16 = 0x4000
    private var queue: [(key: String, payload: [UInt8])] = []
    private var pumping = false
    private var pendingSince: [Date?] = [nil, nil, nil, nil]

    func start() {
        link.onConnect = { pid in Task { @MainActor in self.didConnect(productID: pid) } }
        link.onDisconnect = { Task { @MainActor in self.didDisconnect() } }
        link.onBytes = { bytes in Task { @MainActor in self.receive(bytes) } }
        link.start()
    }

    // MARK: Commands

    func setGain(slot: Int, dB: Int) {
        let value = max(-12, min(12, dB))
        pendingGain[slot] = value
        pendingSince[slot] = Date()
        enqueue("gain.\(slot)", target: MicProtocol.slotMasks[slot], param: .gain, value: [UInt8(bitPattern: Int8(value))])
    }

    func setNoiseCancellation(_ nc: NoiseCancellation) {
        enqueue("nc.on", target: MicProtocol.allTransmitters, param: .noiseCancellation, value: [nc == .off ? 0 : 1])
        if nc != .off {
            enqueue("nc.strong", target: MicProtocol.allTransmitters, param: .noiseStrong, value: [nc == .strong ? 1 : 0])
        }
    }

    func setLowCut(_ on: Bool) {
        enqueue("lowcut", target: MicProtocol.allTransmitters, param: .lowCut, value: [on ? 1 : 0])
    }

    /// Switching to or from quad restarts the receiver; the link reconnects on its own.
    func setMode(_ mode: ChannelMode) {
        guard mode != status?.mode else { return }
        if mode == .quad || status?.mode == .quad { switchingMode = true }
        enqueue("mode", target: MicProtocol.receiverTarget, param: .channelMode, value: [mode.rawValue])
    }

    /// Starts or stops the transmitters' internal recording on every connected slot.
    func setTransmitterRecording(_ on: Bool) {
        if on {
            enqueue("time", target: MicProtocol.receiverTarget, param: .timeSync, value: MicProtocol.timeSyncValue())
        }
        for slot in 0..<4 where transmitters[slot]?.status != nil {
            enqueue("rec.\(slot)", target: MicProtocol.slotMasks[slot], param: .record, value: [on ? 1 : 0])
        }
    }

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
        guard !pumping, connected, !queue.isEmpty else { return }
        pumping = true
        let next = queue.removeFirst()
        seq &+= 1
        let frame = DUMLFrame(sender: MicProtocol.host, receiver: MicProtocol.receiverAddress, seq: seq,
                              type: 0x40, cmdSet: MicProtocol.cmdSet, cmdID: MicProtocol.cmdSetParam, payload: next.payload)
        link.send(frame.encoded())
        log.info("sent \(next.key, privacy: .public)")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            self.pumping = false
            self.pump()
        }
    }

    // MARK: Incoming

    private func didConnect(productID: Int) {
        connected = true
        self.productID = productID
        switchingMode = false
        parser = DUMLParser()
        pump()
    }

    private func didDisconnect() {
        connected = false
        status = nil
        transmitters = [nil, nil, nil, nil]
        pendingGain = [nil, nil, nil, nil]
    }

    private func receive(_ bytes: [UInt8]) {
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
        var next: [TransmitterInfo?] = [nil, nil, nil, nil]
        for record in records {
            if record.field == 0x03, record.device == 0 {
                status = ReceiverStatus(value: record.value)
            } else if record.field == 0x02, let slot = MicProtocol.slotMasks.firstIndex(of: record.device) {
                next[slot] = TransmitterInfo(identity: transmitters[slot]?.identity, status: TransmitterStatus(value: record.value))
            }
        }
        for slot in 0..<4 {
            if let wanted = pendingGain[slot] {
                let confirmed = next[slot]?.status?.gainDB == wanted
                let expired = (pendingSince[slot].map { Date().timeIntervalSince($0) } ?? 0) > 2.5
                if confirmed || expired {
                    if expired && !confirmed { log.error("gain for slot \(slot + 1) not confirmed") }
                    pendingGain[slot] = nil
                }
            }
        }
        if next != transmitters { transmitters = next }
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
            } else if let slot = MicProtocol.slotMasks.firstIndex(of: device), transmitters[slot]?.identity != id {
                var info = transmitters[slot] ?? TransmitterInfo()
                info.identity = id
                transmitters[slot] = info
            }
        }
    }
}
