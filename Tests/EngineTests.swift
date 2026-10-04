import Foundation
import Testing
@testable import Lavboard

@MainActor
struct EngineTests {
    /// The app asks for microphone access before starting the engine; setting tracks or a module
    /// refresh in the meantime must not reach any audio device, or the engine would hang behind
    /// the permission dialog.
    @Test func touchesNoAudioDeviceUntilStarted() async throws {
        let engine = AudioEngine()
        engine.setTracks([(UUID(), .transmitter(system: "dji-mic-mini-2s", slot: 0))])
        engine.refresh()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!engine.layoutPending)
        #expect(engine.state == .idle)
        #expect(engine.inputs.isEmpty && engine.outputs.isEmpty) // no device scan ran
    }
}
