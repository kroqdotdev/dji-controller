import AppKit
import Foundation
import Observation

struct StripSettings: Codable, Equatable {
    var name: String
    var color: TapeColor = .white
    var faderDB: Double = 0
    var sendToVenue = true

    init(name: String) {
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(TapeColor.self, forKey: .color) ?? .white
        faderDB = try c.decodeIfPresent(Double.self, forKey: .faderDB) ?? 0
        sendToVenue = try c.decodeIfPresent(Bool.self, forKey: .sendToVenue) ?? true
    }
}

/// Console tape colours; all light enough for dark ink. Pink stands in for red so a
/// label never reads as "muted".
enum TapeColor: String, Codable, CaseIterable, Identifiable {
    case white, yellow, orange, pink, green, blue, violet

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
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
    @ObservationIgnored let meters = MeterBallistics()

    var strips: [StripSettings] {
        didSet { pushToEngine(); save() }
    }
    /// Mutes are deliberately not persisted: every launch starts with all mics live.
    var muted: [Bool] = [false, false, false, false] {
        didSet { pushToEngine() }
    }
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

    init() {
        let defaults = UserDefaults.standard
        strips = defaults.data(forKey: "strips").flatMap { try? JSONDecoder().decode([StripSettings].self, from: $0) }
            ?? (1...4).map { StripSettings(name: "Mic \($0)") }
        streamLevelDB = defaults.object(forKey: "streamLevelDB") as? Double ?? 0
        venueLevelDB = defaults.object(forKey: "venueLevelDB") as? Double ?? 0
        backupOnTransmitters = defaults.bool(forKey: "backupOnTransmitters")

        pushToEngine()
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
        #if DEBUG
        DebugBridge.install(self)
        #endif
    }

    /// Builds from before the rename to Lavboard saved settings under the old bundle identifier.
    /// Copies them once, on the first launch that finds no Lavboard settings yet.
    private static func migrateLegacySettings() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "strips") == nil,
              let legacy = UserDefaults(suiteName: "com.sauerdev.djicontroller") else { return }
        let keys = ["strips", "streamLevelDB", "venueLevelDB", "backupOnTransmitters", "streamOutputUID",
                    "venueOutputUID", "bufferFrames", "recordingFolder", "recordingFormat"]
        for key in keys {
            if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }

    func toggleMute(_ index: Int) {
        muted[index].toggle()
    }

    var canRecord: Bool { engine.state == .running && !updates.isBusy }

    func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
            if backupOnTransmitters { receiver.setTransmitterRecording(false) }
        } else {
            recorder.start(core: engine.core, trackNames: strips.map(\.name))
            if backupOnTransmitters && recorder.isRecording { receiver.setTransmitterRecording(true) }
        }
    }

    private func stopRecordingForQuit() {
        guard recorder.isRecording else { return }
        recorder.stop()
        if backupOnTransmitters { receiver.setTransmitterRecording(false) }
    }

    private func pushToEngine() {
        for (i, strip) in strips.enumerated() {
            engine.setChannel(i, gainDB: strip.faderDB, muted: muted[i], venueSend: strip.sendToVenue)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(strips) { UserDefaults.standard.set(data, forKey: "strips") }
    }

    /// A click anywhere in the main window outside the field being edited ends editing,
    /// so the 1-4 mute keys never end up typing into a name.
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

    /// Number keys 1-4 toggle mutes, unless a text field is being edited.
    private func installMuteKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  !(NSApp.keyWindow?.firstResponder is NSTextView),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let key = event.charactersIgnoringModifiers, let n = Int(key), (1...4).contains(n)
            else { return event }
            MainActor.assumeIsolated { self.toggleMute(n - 1) }
            return nil
        }
    }
}
