#if DEBUG
import AppKit
import Foundation
import MicSystemKit

/// Debug builds only: accepts commands over a distributed notification so the app can be
/// exercised end to end from a shell (see tools/lavctl.swift).
@MainActor
enum DebugBridge {
    static let name = Notification.Name("com.sauerdev.lavboard.debug")

    static func install(_ app: AppModel) {
        receiver.app = app
        // Deliver even while the app is in the background; the block-based API would hold
        // notifications until the app becomes active.
        DistributedNotificationCenter.default().addObserver(receiver, selector: #selector(Receiver.received(_:)),
                                                            name: name, object: nil, suspensionBehavior: .deliverImmediately)
    }

    private static let receiver = Receiver()

    private final class Receiver: NSObject {
        weak var app: AppModel?

        @objc func received(_ note: Notification) {
            guard let command = note.object as? String else { return }
            MainActor.assumeIsolated {
                if let app { DebugBridge.handle(command, app) }
            }
        }
    }

    fileprivate static func handle(_ command: String, _ app: AppModel) {
        let parts = command.split(separator: " ").map(String.init)
        guard let verb = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        // Everything after the command word, so file paths may contain spaces.
        let rest = String(command.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
        let number = Int(parts.last ?? "") ?? 0
        switch verb {
        case "mode":
            // mode <id>, e.g. "mode quad" for the DJI Mic Mini 2S
            app.micSystems.first { $0.isConnected && $0.modes.contains { $0.id == arg } }?.setMode(arg)
        case "mute":
            app.toggleMute((Int(arg) ?? 1) - 1)
        case "gain":
            // gain <TX 1...> <dB>, on the first system that has hardware gain
            app.micSystems.first { $0.gain != nil }?.setGain(Double(number), slot: (Int(arg) ?? 1) - 1)
        case "fader":
            let i = (Int(arg) ?? 1) - 1
            if app.tracks.indices.contains(i) { app.tracks[i].faderDB = Double(number) }
        case "balance":
            let i = (Int(arg) ?? 1) - 1
            if app.tracks.indices.contains(i) { app.tracks[i].balance = Double(parts.last ?? "") ?? 0 }
        case "label" where parts.count >= 3:
            let i = (Int(arg) ?? 1) - 1
            guard app.tracks.indices.contains(i) else { break }
            app.tracks[i].color = TapeColor(rawValue: parts[2]) ?? .white
            if parts.count > 3 { app.tracks[i].name = parts[3...].joined(separator: " ") }
        case "addtx":
            // addtx <TX 1...> [system id], defaulting to the first registered system
            let slot = (Int(arg) ?? 1) - 1
            let system = parts.count > 2 ? parts[2] : app.micSystems.first.map { type(of: $0).id } ?? TrackSource.legacySystemID
            app.addTrack(.transmitter(system: system, slot: slot), name: "TX\(slot + 1)")
        case "adddevice":
            // adddevice <name or uid fragment> <channel 1...> [stereo]
            guard parts.count >= 3, let channel = Int(parts[2]), channel >= 1,
                  let device = app.engine.inputs.first(where: { $0.uid.contains(arg) || $0.name.localizedCaseInsensitiveContains(arg) })
            else { break }
            let stereo = parts.count > 3 && parts[3] == "stereo"
            app.addTrack(.device(uid: device.uid, name: device.name, channel: channel - 1, stereo: stereo),
                         name: Track.defaultName(deviceName: device.name, channel: channel - 1, stereo: stereo, deviceChannels: device.inputChannels))
        case "addapp":
            // addapp <app name or bundle ID fragment> | addapp system
            if arg == "system" {
                app.addTrack(.systemAudio, name: "Mac audio")
            } else if let match = AppAudio.apps(from: AppAudio.processes()).first(where: {
                $0.bundleID.localizedCaseInsensitiveContains(rest) || $0.name.localizedCaseInsensitiveContains(rest)
            }) {
                app.addTrack(.app(bundleID: match.bundleID, name: match.name), name: match.name)
            }
        case "movetrack" where parts.count >= 3:
            // movetrack <track 1...> <offset>
            let i = (Int(arg) ?? 1) - 1
            if app.tracks.indices.contains(i), let offset = Int(parts[2]) { app.moveTrack(app.tracks[i].id, by: offset) }
        case "removetrack":
            let i = (Int(arg) ?? 1) - 1
            if app.tracks.indices.contains(i) { app.removeTrack(app.tracks[i].id) }
        case "update":
            app.updates.install()
        case "checkupdates":
            app.updates.checkNow()
        case "record":
            app.toggleRecording()
        case "snapshot":
            AppDelegate.snapshot(to: rest)
        case "capture":
            captureWindow(to: rest)
        case "status":
            writeStatus(app, to: rest)
        default:
            break
        }
    }

    /// Captures the main window as the window server draws it, toolbar glass and shadow included.
    /// CGWindowListCreateImage is unavailable in the macOS 15 SDK but still present at runtime, and
    /// an app may capture its own windows without Screen Recording permission.
    private static func captureWindow(to path: String) {
        guard let window = NSApp.windows.filter({ $0.isVisible && $0.canBecomeMain }).max(by: { $0.frame.width < $1.frame.width }),
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // kCGWindowListOptionIncludingWindow, kCGWindowImageBestResolution
            guard let image = create(.null, 1 << 3, CGWindowID(window.windowNumber), 1 << 3)?.takeRetainedValue() else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
        }
    }

    private static func writeStatus(_ app: AppModel, to path: String) {
        let meters = app.engine.readMeters()
        let left = withUnsafeBytes(of: meters.peakLeft) { Array($0.bindMemory(to: Float.self)) }
        let right = withUnsafeBytes(of: meters.peakRight) { Array($0.bindMemory(to: Float.self)) }
        let db = { (v: Float) -> Double in v > 0 ? Double(20 * log10(v)) : -200 }
        let engineState: String
        switch app.engine.state {
        case .running: engineState = "running"
        case .idle: engineState = "idle"
        case .waitingForInputs: engineState = "waiting"
        case .failed(let m): engineState = "failed: \(m)"
        }
        // The first system keeps the flat fields older scripts read (tools/readme-screenshot.sh).
        let first = app.micSystems.first
        let status: [String: Any] = [
            "receiverConnected": first?.isConnected ?? false,
            "mode": first?.currentModeID ?? "-",
            "transmitters": (first?.transmitters ?? []).enumerated().map { i, tx in
                ["slot": i + 1, "connected": tx.connected, "gain": tx.gainDB ?? 0,
                 "pendingGain": tx.pendingGainDB as Any, "battery": tx.battery ?? -1] as [String: Any]
            },
            "micSystems": app.micSystems.map { system in
                ["id": type(of: system).id, "connected": system.isConnected, "receiverPresent": app.isReceiverPresent(system),
                 "mode": system.currentModeID ?? "-", "notice": system.notice?.message ?? "-"] as [String: Any]
            },
            "engine": engineState,
            "engineWarning": app.engine.warning ?? "-",
            "venueLatencyMs": app.engine.venueLatencyMs ?? -1,
            "canRecord": app.canRecord,
            "micAccess": String(describing: app.micAccess),
            "ownClock": app.engine.ownClockStats().map { own in
                ["name": own.name, "rate": own.rate, "running": own.stats.running,
                 "bufferedMs": own.stats.bufferedFrames / own.rate * 1000, "correctionPpm": own.stats.correction * 1e6,
                 "underruns": own.stats.underruns, "overflows": own.stats.overflows] as [String: Any]
            },
            "trackLatencyMs": app.engine.trackLatencyMs.map { $0 ?? -1 },
            "audioApps": AppAudio.apps(from: AppAudio.processes()).map { "\($0.name) [\($0.processes.count)\($0.playing ? ", playing" : "")]" },
            "tracks": app.tracks.enumerated().map { i, track in
                ["name": track.name, "source": track.source.channelLabel, "stereo": track.source.isStereo,
                 "available": app.engine.trackAvailable.indices.contains(i) && app.engine.trackAvailable[i],
                 "muted": app.isMuted(track), "peakLeftDB": db(left[i]), "peakRightDB": db(right[i])] as [String: Any]
            },
            "inputs": app.engine.inputs.map { "\($0.name) [\($0.inputChannels) ch\($0.canJoinEngine ? "" : ", async")]" },
            "bufferFrames": app.engine.actualBufferFrames,
            "callbacks": meters.callbacks,
            "streamPeakDB": db(meters.streamPeak),
            "venuePeakDB": db(meters.venuePeak),
            "uiLevelsDB": app.meters.tracks.prefix(app.tracks.count).map { Double($0.left.level) },
            "recording": app.recorder.isRecording,
            "lastFolder": app.recorder.lastFolder?.path ?? "",
            "recorderError": app.recorder.error ?? "",
            "update": String(describing: app.updates.state),
            "updateFeed": app.updates.feedURL,
            "updateError": app.updates.lastErrorDetail,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
