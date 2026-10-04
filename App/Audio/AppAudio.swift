import AppKit
import CoreAudio
import Darwin

/// A running app whose audio can become a track, with the CoreAudio processes playing on its
/// behalf. Helpers such as a browser's web-content or renderer processes belong to the app
/// responsible for them, so tapping "Safari" includes the tab that is actually playing.
struct AudioApp: Identifiable, Equatable {
    var bundleID: String
    var name: String
    var processes: [AudioObjectID]
    /// Whether any of its processes is playing right now.
    var playing: Bool

    var id: String { bundleID }
}

/// Finds apps and processes for CoreAudio process taps.
enum AppAudio {
    /// Apps that play the stream back for monitoring. Capturing them in "All Mac audio" would feed
    /// the stream into itself.
    static let streamingApps: Set<String> = ["com.obsproject.obs-studio", "com.streamlabs.slobs"]

    /// One CoreAudio process object.
    struct Process: Equatable {
        var object: AudioObjectID
        var pid: pid_t
        var bundleID: String
        var playing: Bool
    }

    static func processes() -> [Process] {
        var addr = CoreAudioHAL.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.map { object in
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = CoreAudioHAL.address(kAudioProcessPropertyPID)
            AudioObjectGetPropertyData(object, &pidAddr, 0, nil, &pidSize, &pid)
            return Process(object: object, pid: pid,
                           bundleID: CoreAudioHAL.string(object, kAudioProcessPropertyBundleID) ?? "",
                           playing: CoreAudioHAL.uint32(object, kAudioProcessPropertyIsRunningOutput) != 0)
        }
    }

    /// Lavboard's own process object, which must never be captured: its outputs carry the mix.
    static func ownProcess(in processes: [Process]) -> AudioObjectID? {
        processes.first { $0.pid == getpid() }?.object
    }

    /// Running apps that have opened audio, by name, with their processes.
    @MainActor
    static func apps(from processes: [Process]) -> [AudioApp] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let byPID = Dictionary(running.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        let ownBundle = Bundle.main.bundleIdentifier
        var apps: [String: AudioApp] = [:]
        for process in processes {
            guard let app = byPID[process.pid] ?? byPID[responsiblePID(for: process.pid)],
                  let bundleID = app.bundleIdentifier, bundleID != ownBundle else { continue }
            var entry = apps[bundleID] ?? AudioApp(bundleID: bundleID, name: app.localizedName ?? bundleID, processes: [], playing: false)
            entry.processes.append(process.object)
            entry.playing = entry.playing || process.playing
            apps[bundleID] = entry
        }
        return apps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The app process responsible for a helper process (the same pid if it is an app).
    static func responsiblePID(for pid: pid_t) -> pid_t {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        // Not in the public headers, but present in libsystem for years; looked up at runtime so a
        // missing symbol just means helpers aren't grouped under their app.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return pid }
        let responsible = unsafeBitCast(symbol, to: Responsible.self)(pid)
        return responsible > 0 ? responsible : pid
    }
}

/// What a tap captures.
struct TapSpec: Equatable {
    /// The track source identity this tap serves.
    var identity: String
    var name: String
    /// Everything except these processes, or only these processes.
    var global: Bool
    var processes: [AudioObjectID]

    func description() -> CATapDescription {
        let description = global ? CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
                                 : CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "Lavboard: \(name)"
        description.isPrivate = true
        description.muteBehavior = .unmuted // the app keeps playing on the Mac as usual
        return description
    }
}
