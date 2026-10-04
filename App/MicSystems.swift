import DJIMicMini2S
import Foundation
import MicSystemKit
import Observation

/// Every wireless mic system Lavboard supports. Each lives in its own package under `Packages/`;
/// to add one, write its module and list its type here (see CONTRIBUTING.md).
enum MicSystems {
    static var all: [any MicSystem.Type] {
        var systems: [any MicSystem.Type] = [
            DJIMicMini2S.self,
        ]
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "FakeMicSystem") { systems.append(FakeMicSystem.self) }
        #endif
        return systems
    }
}

#if DEBUG
/// A pretend two-transmitter system for working on the interface without wireless hardware. Its
/// "receiver" is the Mac's built-in microphone, which carries TX1; TX2 has no channel of its own.
/// Every capability is simulated, so all the controls appear. Turn it on with
/// `defaults write com.sauerdev.lavboard.debug FakeMicSystem -bool true` and relaunch a debug build.
@Observable @MainActor
final class FakeMicSystem: MicSystem {
    static let id = "fake"
    static let name = "Fake mic system"
    static let transmitterCount = 2

    static func isReceiver(_ device: AudioDeviceDescription) -> Bool {
        device.uid == "BuiltInMicrophoneDevice"
    }

    private var state = [TransmitterState(connected: true, battery: 0.8, gainDB: 0),
                         TransmitterState(connected: false)]
    private var mode = "split"
    private var lowCut = false
    private var noise = "off"

    init() {}

    func start() {
        // Drain the battery slowly so the gauge visibly moves.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let level = self.state[0].battery else { return }
                self.state[0].battery = max(0, level - 0.01)
            }
        }
    }

    var isConnected: Bool { true }
    var transmitters: [TransmitterState] { state }
    func audioChannel(forSlot slot: Int) -> Int? { mode == "split" && slot == 0 ? 0 : nil }

    var gain: GainCapability? { GainCapability(range: -10...10, step: 2) }
    func setGain(_ dB: Double, slot: Int) {
        state[slot].pendingGainDB = dB
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            self.state[slot].gainDB = dB
            self.state[slot].pendingGainDB = nil
        }
    }

    var canRecordOnTransmitters: Bool { true }
    func setTransmitterRecording(_ on: Bool) {
        for slot in state.indices where state[slot].connected { state[slot].recording = on }
    }

    var modes: [ReceiverMode] { [ReceiverMode(id: "split", name: "Split"), ReceiverMode(id: "merged", name: "Merged")] }
    var currentModeID: String? { mode }
    func setMode(_ id: String) { mode = id }
    func modeSwitchWarning(to id: String) -> String? { id == "merged" ? "Merged mode mixes every mic into one channel." : nil }

    var settings: [MicSetting] {
        [MicSetting(id: "noise", title: "Noise cancellation",
                    kind: .choice([("off", "Off"), ("on", "On")]), value: .choice(noise)),
         MicSetting(id: "lowCut", title: "Low cut", kind: .toggle, value: .toggle(lowCut))]
    }
    var settingsNote: String? { "Pretend settings; nothing is sent anywhere." }
    func set(_ settingID: String, to value: MicSettingValue) {
        switch (settingID, value) {
        case ("noise", .choice(let v)): noise = v
        case ("lowCut", .toggle(let v)): lowCut = v
        default: break
        }
    }

    var notice: MicNotice? {
        mode == "merged" ? MicNotice(message: "The fake receiver is in merged mode, so TX1 has no channel of its own.",
                                     actionTitle: "Switch to split", modeID: "split") : nil
    }
}
#endif
