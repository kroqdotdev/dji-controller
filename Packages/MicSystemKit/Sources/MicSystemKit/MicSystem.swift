import Foundation
import Observation

/// A wireless mic system Lavboard can show and control, such as the DJI Mic Mini 2S.
///
/// A module does two things the app can't: it recognises its receiver's audio device, and it says
/// which audio channel carries each transmitter. Everything else is an optional capability. Leave
/// out what the hardware doesn't support (or what nobody has worked out yet) and the app simply
/// doesn't show that control. A module never draws UI: the app renders gain, battery, modes and
/// settings from what the module reports, so every system looks at home on the console.
///
/// Conform with an `@Observable @MainActor final class`, register the type in the app's
/// `MicSystems.all`, and see CONTRIBUTING.md ("Adding a mic system").
@MainActor
public protocol MicSystem: AnyObject, Observable {
    /// Stable identifier, saved in settings with every track that uses this system. Never change
    /// it once a version with it has shipped. Lowercase with dashes, e.g. "dji-mic-mini-2s".
    static var id: String { get }
    /// Product name shown to the user, e.g. "DJI Mic Mini 2S".
    static var name: String { get }
    /// Number of transmitter slots, shown as TX1, TX2 and so on.
    static var transmitterCount: Int { get }
    /// Whether a CoreAudio input device is this system's receiver. For USB devices the model UID
    /// contains the vendor and product IDs as "VVVV:PPPP" in hex, which is the most reliable match.
    static func isReceiver(_ device: AudioDeviceDescription) -> Bool

    init()
    /// Called once at launch. Start watching for the receiver's control interface here, if the
    /// module has one. Audio works without it.
    func start()

    /// Whether the control link to the receiver is up. Audio-only modules leave this false.
    var isConnected: Bool { get }
    /// One entry per slot, `transmitterCount` long. Audio-only modules can return disconnected
    /// entries; the app then shows no battery and no gain for them.
    var transmitters: [TransmitterState] { get }
    /// The receiver audio channel (0-based) that carries `slot` right now, or nil if that
    /// transmitter has no channel of its own, for example in a mode that mixes all mics together.
    /// The app also checks that the channel exists on the receiver's audio device.
    func audioChannel(forSlot slot: Int) -> Int?

    // MARK: Optional capabilities

    /// Hardware gain on the transmitters, if the module can set it.
    var gain: GainCapability? { get }
    /// Sets a transmitter's hardware gain. Report it as `pendingGainDB` until the receiver confirms.
    func setGain(_ dB: Double, slot: Int)

    /// Whether the transmitters can record on their own storage as a backup.
    var canRecordOnTransmitters: Bool { get }
    /// Starts or stops recording on every connected transmitter. Called when Lavboard starts and
    /// stops recording, if the user turned "Backup on mics" on.
    func setTransmitterRecording(_ on: Bool)

    /// Receiver modes the user can switch between, such as mono, stereo and 4-track.
    var modes: [ReceiverMode] { get }
    var currentModeID: String? { get }
    /// True while the receiver restarts after a mode change; the app hides mode controls meanwhile.
    var isSwitchingMode: Bool { get }
    func setMode(_ id: String)
    /// A warning to confirm before switching to `id`, e.g. that the receiver restarts. Nil switches
    /// straight away.
    func modeSwitchWarning(to id: String) -> String?

    /// Settings that apply to the whole system, such as noise cancellation. Shown in Settings.
    var settings: [MicSetting] { get }
    /// A line under the settings, e.g. "Applies to every connected mic."
    var settingsNote: String? { get }
    func set(_ settingID: String, to value: MicSettingValue)

    /// Something the user should do, shown as a banner while a track uses this system.
    var notice: MicNotice? { get }
}

public extension MicSystem {
    var gain: GainCapability? { nil }
    func setGain(_ dB: Double, slot: Int) {}
    var canRecordOnTransmitters: Bool { false }
    func setTransmitterRecording(_ on: Bool) {}
    var modes: [ReceiverMode] { [] }
    var currentModeID: String? { nil }
    var isSwitchingMode: Bool { false }
    func setMode(_ id: String) {}
    func modeSwitchWarning(to id: String) -> String? { nil }
    var settings: [MicSetting] { [] }
    var settingsNote: String? { nil }
    func set(_ settingID: String, to value: MicSettingValue) {}
    var notice: MicNotice? { nil }
}

/// The parts of a CoreAudio device a module needs to recognise its receiver.
public struct AudioDeviceDescription: Sendable, Equatable {
    public var uid: String
    public var name: String
    /// `kAudioDevicePropertyModelUID`; contains "VVVV:PPPP" (USB vendor and product ID) for USB devices.
    public var modelUID: String
    public var inputChannels: Int

    public init(uid: String, name: String, modelUID: String, inputChannels: Int) {
        self.uid = uid
        self.name = name
        self.modelUID = modelUID
        self.inputChannels = inputChannels
    }

    /// Whether this is the USB device with the given vendor ID and one of the product IDs.
    public func isUSB(vendor: Int, products: [Int]) -> Bool {
        let model = modelUID.uppercased()
        return products.contains { model.contains(String(format: "%04X:%04X", vendor, $0)) }
    }
}

/// What a module knows about one transmitter. Leave fields nil when the hardware doesn't report them.
public struct TransmitterState: Equatable, Sendable {
    /// Whether the transmitter is on and linked to the receiver.
    public var connected: Bool
    /// Remaining battery, 0 (empty) to 1 (full).
    public var battery: Double?
    public var charging: Bool
    /// Hardware gain the receiver last confirmed, in dB.
    public var gainDB: Double?
    /// Gain sent but not yet confirmed; the app shows it faded.
    public var pendingGainDB: Double?
    /// Whether it is recording on its own storage.
    public var recording: Bool
    public var serial: String?

    public init(connected: Bool = false, battery: Double? = nil, charging: Bool = false, gainDB: Double? = nil,
                pendingGainDB: Double? = nil, recording: Bool = false, serial: String? = nil) {
        self.connected = connected
        self.battery = battery
        self.charging = charging
        self.gainDB = gainDB
        self.pendingGainDB = pendingGainDB
        self.recording = recording
        self.serial = serial
    }
}

public struct GainCapability: Sendable, Equatable {
    public var range: ClosedRange<Double>
    public var step: Double

    public init(range: ClosedRange<Double>, step: Double) {
        self.range = range
        self.step = step
    }
}

public struct ReceiverMode: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum MicSettingValue: Hashable, Sendable {
    case toggle(Bool)
    case choice(String)
}

public struct MicSetting: Identifiable, Sendable {
    public enum Kind: Sendable {
        case toggle
        /// Options as (id, name) pairs, shown in order.
        case choice([(id: String, name: String)])
    }

    public var id: String
    public var title: String
    public var kind: Kind
    /// The current value, or nil when it isn't known (the app disables the control).
    public var value: MicSettingValue?

    public init(id: String, title: String, kind: Kind, value: MicSettingValue?) {
        self.id = id
        self.title = title
        self.kind = kind
        self.value = value
    }
}

public struct MicNotice: Sendable, Equatable {
    public var message: String
    /// A button that switches to `modeID`, if the fix is a mode change.
    public var actionTitle: String?
    public var modeID: String?

    public init(message: String, actionTitle: String? = nil, modeID: String? = nil) {
        self.message = message
        self.actionTitle = actionTitle
        self.modeID = modeID
    }
}
