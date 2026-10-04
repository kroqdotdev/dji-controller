import MicSystemKit
import Testing
@testable import DJIMicMini2S

@MainActor
struct DJIMicMini2STests {
    /// A status push captured from a receiver in mono mode with TX2 on.
    static let statusPush = ProtocolTests.bytes("555604675a02d4f1005b03034600030000000020a8310000000000000000000000000000000000000f000000020000001200000002020000001ab025044900780000dd00dd000000000000000000000000000000776a")

    @Test func keepsItsSettingsIdentifier() {
        // Saved in every track's settings; changing it would orphan existing tracks.
        #expect(DJIMicMini2S.id == "dji-mic-mini-2s")
    }

    @Test func recognisesTheReceiverInEveryMode() {
        func device(_ model: String) -> AudioDeviceDescription {
            AudioDeviceDescription(uid: "u", name: "Wireless Mic Rx", modelUID: model, inputChannels: 4)
        }
        #expect(DJIMicMini2S.isReceiver(device("Wireless Mic Rx:2CA3:4015")))
        #expect(DJIMicMini2S.isReceiver(device("Wireless Mic Rx:2CA3:4115")))
        #expect(!DJIMicMini2S.isReceiver(device("Realtek USB2.0 Audio:0BDA:4BB2")))
    }

    @Test func reportsTransmittersAndSettingsFromAStatusPush() {
        let system = DJIMicMini2S()
        system.receive(Self.statusPush)
        let tx = system.transmitters
        #expect(tx.count == 4)
        #expect(!tx[0].connected && tx[1].connected && !tx[2].connected && !tx[3].connected)
        #expect(tx[1].gainDB == 0 && tx[1].pendingGainDB == nil && !tx[1].recording)
        #expect(tx[1].battery.map { (0...1).contains($0) } == true)

        let noise = system.settings.first { $0.id == "noise" }
        #expect(noise?.value == .choice("strong"))
        #expect(system.settings.first { $0.id == "lowCut" }?.value == .toggle(false))
        #expect(system.settingsNote == "Applies to every connected mic.")
    }

    @Test func settingsAreUnknownUntilAMicIsOn() {
        let system = DJIMicMini2S()
        #expect(system.settings.allSatisfy { $0.value == nil })
        #expect(system.settingsNote == "Switch on a mic to change these.")
        #expect(system.transmitters.allSatisfy { !$0.connected })
    }

    @Test func mapsEachSlotToItsOwnChannel() {
        let system = DJIMicMini2S()
        #expect((0..<4).map(system.audioChannel(forSlot:)) == [0, 1, 2, 3])
        #expect(system.audioChannel(forSlot: 4) == nil)
    }

    @Test func warnsBeforeARestartingModeSwitch() {
        let system = DJIMicMini2S()
        #expect(system.modes.map(\.id) == ["mono", "stereo", "quad"])
        #expect(system.modeSwitchWarning(to: "quad") != nil)
        #expect(system.modeSwitchWarning(to: "stereo") == nil)
    }
}
