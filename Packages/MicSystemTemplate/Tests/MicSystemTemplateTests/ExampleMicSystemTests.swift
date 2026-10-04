import MicSystemKit
import Testing
@testable import MicSystemTemplate

@MainActor
struct ExampleMicSystemTests {
    @Test func recognisesOnlyItsReceiver() {
        let receiver = AudioDeviceDescription(uid: "u", name: "Example Rx", modelUID: "Example Rx:1234:5678", inputChannels: 2)
        let webcam = AudioDeviceDescription(uid: "v", name: "Webcam", modelUID: "Webcam:046D:085C", inputChannels: 2)
        #expect(ExampleMicSystem.isReceiver(receiver))
        #expect(!ExampleMicSystem.isReceiver(webcam))
    }

    @Test func mapsEachTransmitterToAChannel() {
        let system = ExampleMicSystem()
        #expect(system.audioChannel(forSlot: 0) == 0)
        #expect(system.audioChannel(forSlot: 1) == 1)
        #expect(system.audioChannel(forSlot: 2) == nil)
        #expect(system.transmitters.count == ExampleMicSystem.transmitterCount)
    }

    // Once the module speaks the receiver's protocol, decode real captured traffic here, as the
    // DJI module does in Packages/DJIMicMini2S/Tests.
}
