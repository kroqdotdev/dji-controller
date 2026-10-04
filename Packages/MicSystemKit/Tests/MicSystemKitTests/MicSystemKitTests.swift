import Observation
import Testing
@testable import MicSystemKit

/// The smallest possible module: audio only, two transmitters on channels 0 and 1.
@Observable @MainActor
private final class AudioOnlySystem: MicSystem {
    static let id = "test-audio-only"
    static let name = "Test receiver"
    static let transmitterCount = 2
    static func isReceiver(_ device: AudioDeviceDescription) -> Bool { device.isUSB(vendor: 0x1234, products: [0x0001]) }

    init() {}
    func start() {}
    var isConnected: Bool { false }
    var transmitters: [TransmitterState] { Array(repeating: TransmitterState(), count: Self.transmitterCount) }
    func audioChannel(forSlot slot: Int) -> Int? { slot }
}

@MainActor
struct MicSystemKitTests {
    @Test func optionalCapabilitiesDefaultToUnsupported() {
        let system: any MicSystem = AudioOnlySystem()
        #expect(system.gain == nil)
        #expect(!system.canRecordOnTransmitters)
        #expect(system.modes.isEmpty && system.currentModeID == nil && !system.isSwitchingMode)
        #expect(system.settings.isEmpty && system.settingsNote == nil)
        #expect(system.notice == nil)
        #expect(system.modeSwitchWarning(to: "any") == nil)
    }

    @Test func matchesUSBDevicesByVendorAndProduct() {
        let receiver = AudioDeviceDescription(uid: "u", name: "Rx", modelUID: "Rx:1234:0001", inputChannels: 2)
        let other = AudioDeviceDescription(uid: "v", name: "Rx", modelUID: "Rx:1234:0002", inputChannels: 2)
        #expect(AudioOnlySystem.isReceiver(receiver))
        #expect(!AudioOnlySystem.isReceiver(other))
        // Model UIDs from CoreAudio may use lowercase hex.
        let lower = AudioDeviceDescription(uid: "w", name: "Rx", modelUID: "rx:1234:000a", inputChannels: 2)
        #expect(lower.isUSB(vendor: 0x1234, products: [0x000A]))
    }
}
