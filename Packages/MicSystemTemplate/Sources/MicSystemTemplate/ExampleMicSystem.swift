import Foundation
import MicSystemKit
import Observation

/// An audio-only module for a made-up two-transmitter receiver: the smallest thing that works.
///
/// With just `isReceiver` and `audioChannel`, the receiver's transmitters appear as TX1 and TX2
/// under Add track, with names, meters, faders and mutes. Add capabilities from `MicSystem` (gain,
/// battery, modes, settings) as you work out the receiver's control protocol; the app shows each
/// control as soon as the module reports it.
@Observable @MainActor
public final class ExampleMicSystem: MicSystem {
    /// Saved with every track that uses this system: pick it once and never change it.
    public static let id = "example-wireless"
    public static let name = "Example Wireless"
    public static let transmitterCount = 2

    /// Find the receiver's USB IDs in System Information > USB, or in the CoreAudio model UID.
    public static func isReceiver(_ device: AudioDeviceDescription) -> Bool {
        device.isUSB(vendor: 0x1234, products: [0x5678])
    }

    public init() {}

    /// Open the receiver's control channel here once there is one (see `ControlLink`).
    public func start() {}

    /// No control link yet, so the app doesn't claim to know which mics are on.
    public var isConnected: Bool { false }

    public var transmitters: [TransmitterState] {
        Array(repeating: TransmitterState(), count: Self.transmitterCount)
    }

    /// In this receiver's split mode, TX1 is the left channel and TX2 the right.
    public func audioChannel(forSlot slot: Int) -> Int? {
        (0..<Self.transmitterCount).contains(slot) ? slot : nil
    }
}
