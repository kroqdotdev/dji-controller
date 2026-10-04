import AppKit
import Foundation
import Observation
import SwiftUI

/// Console tape colours; all light enough for dark ink. Pink stands in for red so a
/// label never reads as "muted".
enum TapeColor: String, Codable, CaseIterable, Identifiable {
    case white, yellow, orange, pink, green, blue, violet

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// One entry in the source picker.
struct SourceChoice {
    var source: TrackSource
    var title: String
    var defaultName: String
    var inUse: Bool
    var note: String?
}

struct SourceChoices {
    var transmitters: [SourceChoice]
    /// Keyed by UID: two identical USB mics share a name. `note` explains a device on its own clock.
    var devices: [(uid: String, name: String, note: String?, options: [SourceChoice])]
}

@Observable @MainActor
final class AppModel {
    /// Declared first so it runs before the engine and recorder read their saved settings.
    @ObservationIgnored private let legacySettingsMigrated: Void = AppModel.migrateLegacySettings()
    let receiver = ReceiverModel()
    let engine = AudioEngine()
    let recorder = Recorder()
    let streamDevice = StreamDevice()
    let updates = UpdateController()
    let meters = MeterStore()

    /// Up to `Track.maximum` tracks, in strip order.
    var tracks: [Track] {
        didSet { tracksChanged(from: oldValue) }
    }
    /// Muted track IDs. Deliberately not persisted: every launch starts with all mics live.
    var muted: Set<UUID> = [] {
        didSet { pushToEngine() }
    }
    /// Bumped when a device's own input gain is changed, so strips re-read it.
    private(set) var deviceGainRevision = 0
    var streamLevelDB: Double {
        didSet { engine.setStreamLevel(dB: streamLevelDB); UserDefaults.standard.set(streamLevelDB, forKey: "streamLevelDB") }
    }
    var venueLevelDB: Double {
        didSet { engine.setVenueLevel(dB: venueLevelDB); UserDefaults.standard.set(venueLevelDB, forKey: "venueLevelDB") }
    }
    var backupOnTransmitters: Bool {
        didSet { UserDefaults.standard.set(backupOnTransmitters, forKey: "backupOnTransmitters") }
    }

    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var clickMonitor: Any?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var meterTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.data(forKey: "tracks").flatMap({ try? JSONDecoder().decode([Track].self, from: $0) }) {
            tracks = Array(saved.prefix(Track.maximum))
        } else if let legacy = defaults.data(forKey: "strips").flatMap({ try? JSONDecoder().decode([LegacyStripSettings].self, from: $0) }) {
            tracks = LegacyStripSettings.migrate(legacy)
        } else {
            tracks = Track.defaultSet()
        }
        streamLevelDB = defaults.object(forKey: "streamLevelDB") as? Double ?? 0
        venueLevelDB = defaults.object(forKey: "venueLevelDB") as? Double ?? 0
        backupOnTransmitters = defaults.bool(forKey: "backupOnTransmitters")
        // Unit tests run inside the app: keep the test host off the audio devices, the receiver and
        // the saved settings.
        guard !Self.isTestHost else { return }

        engine.trackSources = tracks.map(\.source)
        pushToEngine()
        save()
        engine.setStreamLevel(dB: streamLevelDB)
        engine.setVenueLevel(dB: venueLevelDB)
        engine.start()
        receiver.start()
        updates.shouldDeferRestart = { [weak self] in self?.recorder.isRecording ?? false }
        updates.start()
        // However the app quits (including to install an update), finish recordings cleanly.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecordingForQuit() }
        }
        streamDevice.onInstalled = { [weak self] in
            guard let self else { return }
            // Route the stream mix to the new device unless another output is already in use.
            let current = self.engine.streamOutputUID
            if current == nil || !self.engine.outputs.contains(where: { $0.uid == current }) {
                self.engine.streamOutputUID = StreamDevice.deviceUID
            }
        }

        // Keep timers and audio threads at full priority while the app is open (no App Nap).
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Live audio mixing")
        installMuteKeys()
        installClickToUnfocus()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.meters.update(self.engine.readMeters())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
        #if DEBUG
        DebugBridge.install(self)
        #endif
    }

    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil

    /// Builds from before the rename to Lavboard saved settings under the old bundle identifier.
    /// Copies them once, on the first launch that finds no Lavboard settings yet.
    private static func migrateLegacySettings() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "strips") == nil, defaults.object(forKey: "tracks") == nil,
              let legacy = UserDefaults(suiteName: "com.sauerdev.djicontroller") else { return }
        let keys = ["strips", "streamLevelDB", "venueLevelDB", "backupOnTransmitters", "streamOutputUID",
                    "venueOutputUID", "bufferFrames", "recordingFolder", "recordingFormat"]
        for key in keys {
            if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }

    // MARK: Tracks

    var canAddTrack: Bool { tracks.count < Track.maximum && !recorder.isRecording }
    /// Tracks can't be added, removed or re-sourced mid-recording: the files are fixed at the start.
    var canEditTracks: Bool { !recorder.isRecording }
    var hasTransmitterTracks: Bool { tracks.contains { $0.source.transmitterSlot != nil } }

    func isMuted(_ track: Track) -> Bool { muted.contains(track.id) }

    /// A binding to one field of a track, looked up by ID on every access. Views never hold an
    /// array index, so a control that is still closing after its track was removed (e.g. the name
    /// field ending its edit) writes nowhere instead of crashing.
    func binding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<Track, Value>, fallback: Value) -> Binding<Value> {
        Binding(
            get: { [weak self] in
                MainActor.assumeIsolated { self?.tracks.first(where: { $0.id == id })?[keyPath: keyPath] ?? fallback }
            },
            set: { [weak self] value in
                MainActor.assumeIsolated {
                    guard let self, let i = self.tracks.firstIndex(where: { $0.id == id }) else { return }
                    self.tracks[i][keyPath: keyPath] = value
                }
            })
    }

    func toggleMute(_ index: Int) {
        guard tracks.indices.contains(index) else { return }
        let id = tracks[index].id
        if muted.contains(id) { muted.remove(id) } else { muted.insert(id) }
    }

    func addTrack(_ source: TrackSource, name: String) {
        guard canAddTrack else { return }
        // A Bluetooth mic lags far behind the room, so it stays off the venue PA unless asked.
        let bluetooth = engine.device(for: source)?.isBluetooth ?? false
        tracks.append(Track(name: name, sendToVenue: !bluetooth, source: source))
    }

    func removeTrack(_ id: UUID) {
        guard canEditTracks else { return }
        tracks.removeAll { $0.id == id }
    }

    func setSource(_ source: TrackSource, for id: UUID) {
        guard canEditTracks, let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].source = source
        if !source.isStereo { tracks[i].balance = 0 }
    }

    /// Everything a track could use right now, marking sources other tracks already use.
    func sourceChoices() -> SourceChoices {
        let used = Set(tracks.map(\.source.identity))
        var transmitters: [SourceChoice] = []
        if engine.receiverDevice != nil || receiver.connected {
            transmitters = (0..<4).map { slot in
                let source = TrackSource.transmitter(slot: slot)
                return SourceChoice(source: source, title: "TX\(slot + 1)", defaultName: "Mic \(slot + 1)",
                                    inUse: used.contains(source.identity),
                                    note: receiver.transmitters[slot]?.status == nil ? "Off" : nil)
            }
        }
        let devices = engine.inputs.filter { $0.usableInputChannels > 0 }
            .map { device -> (uid: String, name: String, note: String?, options: [SourceChoice]) in
            let channels = device.usableInputChannels
            func choice(_ channel: Int, stereo: Bool, title: String) -> SourceChoice {
                let source = TrackSource.device(uid: device.uid, name: device.name, channel: channel, stereo: stereo)
                let name = Track.defaultName(deviceName: device.name, channel: channel, stereo: stereo, deviceChannels: channels)
                return SourceChoice(source: source, title: title, defaultName: name, inUse: used.contains(source.identity))
            }
            var options: [SourceChoice] = []
            if channels == 1 {
                options.append(choice(0, stereo: false, title: "Mono input"))
            } else {
                for c in 0..<channels { options.append(choice(c, stereo: false, title: "Input \(c + 1)")) }
                for c in stride(from: 0, to: channels - 1, by: 2) {
                    options.append(choice(c, stereo: true, title: "Inputs \(c + 1) and \(c + 2), stereo"))
                }
            }
            return (device.uid, device.name, Self.ownClockNote(device), options)
        }
        return SourceChoices(transmitters: transmitters, devices: devices)
    }

    /// What to expect from a device that can't run on the engine's 48 kHz clock.
    static func ownClockNote(_ device: AudioDeviceInfo) -> String? {
        if device.isBluetooth {
            return "Bluetooth runs behind the other inputs, and a headset switches to call quality while its mic is in use."
        }
        guard device.runsOnOwnClock else { return nil }
        let rate = CoreAudioHAL.preferredRate(among: CoreAudioHAL.availableRates(device.id)) ?? device.nominalRate
        return "Converted from \(Self.kilohertz(rate)), slightly behind the other inputs."
    }

    static func kilohertz(_ rate: Double) -> String {
        let khz = rate / 1000
        return khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
    }

    func sourceDescription(_ source: TrackSource) -> String {
        switch source {
        case .transmitter: "DJI receiver, \(source.channelLabel)"
        case .device(_, let name, _, _): "\(name), \(source.channelLabel)"
        }
    }

    /// The source device's own input gain, for devices that let apps change it.
    func deviceGain(for track: Track) -> (value: Double, range: ClosedRange<Double>)? {
        _ = deviceGainRevision
        guard track.source.transmitterSlot == nil, let device = engine.device(for: track.source) else { return nil }
        return CoreAudioHAL.inputGain(device.id)
    }

    func setDeviceGain(_ dB: Double, for track: Track) {
        guard let device = engine.device(for: track.source), let current = CoreAudioHAL.inputGain(device.id) else { return }
        CoreAudioHAL.setInputGain(device.id, dB: min(max(dB, current.range.lowerBound), current.range.upperBound))
        deviceGainRevision += 1
    }

    private func tracksChanged(from old: [Track]) {
        if tracks.map(\.source) != old.map(\.source) { engine.trackSources = tracks.map(\.source) }
        muted = muted.intersection(tracks.map(\.id))
        pushToEngine()
        save()
    }

    var canRecord: Bool { engine.state == .running && !engine.layoutPending && !updates.isBusy }

    func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
            if backupOnTransmitters { receiver.setTransmitterRecording(false) }
        } else if canRecord {
            recorder.start(core: engine.core, tracks: tracks.map { ($0.name, $0.source.isStereo ? 2 : 1) })
            if backupOnTransmitters && recorder.isRecording { receiver.setTransmitterRecording(true) }
        }
    }

    private func stopRecordingForQuit() {
        guard recorder.isRecording else { return }
        recorder.stop()
        if backupOnTransmitters { receiver.setTransmitterRecording(false) }
    }

    private func pushToEngine() {
        for (i, track) in tracks.enumerated() {
            engine.setTrack(i, gainDB: track.faderDB, muted: muted.contains(track.id),
                            venueSend: track.sendToVenue, balance: track.balance)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tracks) { UserDefaults.standard.set(data, forKey: "tracks") }
    }

    /// A click anywhere in the main window outside the field being edited ends editing,
    /// so the 1-8 mute keys never end up typing into a name.
    private func installClickToUnfocus() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window, window.canBecomeMain,
                  let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return event }
            if let field = editor.delegate as? NSView,
               field.convert(field.bounds, to: nil).contains(event.locationInWindow) {
                return event
            }
            window.makeFirstResponder(nil)
            return event
        }
    }

    /// Number keys 1-8 toggle mutes, unless a text field is being edited.
    private func installMuteKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  !(NSApp.keyWindow?.firstResponder is NSTextView),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let key = event.charactersIgnoringModifiers, let n = Int(key), (1...Track.maximum).contains(n)
            else { return event }
            MainActor.assumeIsolated { self.toggleMute(n - 1) }
            return nil
        }
    }
}
