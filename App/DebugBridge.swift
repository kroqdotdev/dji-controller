#if DEBUG
import AppKit
import Foundation

/// Debug builds only: accepts commands over a distributed notification so the app can be
/// exercised end to end from a shell (see tools/lavctl.swift).
@MainActor
enum DebugBridge {
    static let name = Notification.Name("com.sauerdev.lavboard.debug")

    static func install(_ app: AppModel) {
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            guard let command = note.object as? String else { return }
            MainActor.assumeIsolated { handle(command, app) }
        }
    }

    private static func handle(_ command: String, _ app: AppModel) {
        let parts = command.split(separator: " ").map(String.init)
        guard let verb = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        let number = Int(parts.last ?? "") ?? 0
        switch verb {
        case "mode":
            app.receiver.setMode(arg == "quad" ? .quad : (arg == "stereo" ? .stereo : .mono))
        case "mute":
            app.toggleMute((Int(arg) ?? 1) - 1)
        case "gain":
            app.receiver.setGain(slot: (Int(arg) ?? 1) - 1, dB: number)
        case "fader":
            app.strips[(Int(arg) ?? 1) - 1].faderDB = Double(number)
        case "label" where parts.count >= 3:
            let i = (Int(arg) ?? 1) - 1
            app.strips[i].color = TapeColor(rawValue: parts[2]) ?? .white
            if parts.count > 3 { app.strips[i].name = parts[3...].joined(separator: " ") }
        case "update":
            app.updates.install()
        case "checkupdates":
            app.updates.checkNow()
        case "record":
            app.toggleRecording()
        case "snapshot":
            AppDelegate.snapshot(to: arg)
        case "capture":
            captureWindow(to: arg)
        case "status":
            writeStatus(app, to: arg)
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
        let peaks = withUnsafeBytes(of: meters.peak) { Array($0.bindMemory(to: Float.self)) }
        let db = { (v: Float) -> Double in v > 0 ? Double(20 * log10(v)) : -200 }
        let engineState: String
        switch app.engine.state {
        case .running: engineState = "running"
        case .waitingForReceiver: engineState = "waiting"
        case .failed(let m): engineState = "failed: \(m)"
        }
        let status: [String: Any] = [
            "receiverConnected": app.receiver.connected,
            "mode": app.receiver.mode?.label ?? "-",
            "transmitters": app.receiver.transmitters.enumerated().map { i, tx in
                ["slot": i + 1, "connected": tx?.status != nil, "gain": tx?.status?.gainDB ?? 0,
                 "pendingGain": app.receiver.pendingGain[i] as Any, "battery": tx?.status?.batteryLevel ?? 0]
            },
            "engine": engineState,
            "inputChannels": app.engine.inputChannels,
            "bufferFrames": app.engine.actualBufferFrames,
            "callbacks": meters.callbacks,
            "peaksDB": peaks.map(db),
            "streamPeakDB": db(meters.streamPeak),
            "venuePeakDB": db(meters.venuePeak),
            "uiLevelsDB": app.meters.channels.map { Double($0.level) },
            "muted": app.muted,
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
