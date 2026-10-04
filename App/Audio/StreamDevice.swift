import AppKit
import Foundation
import Observation
import os

/// Installs the bundled "DJI Controller" virtual audio device (built from BlackHole) so
/// Streamlabs can use the stream mix as a mic. Needs administrator rights once, because audio
/// drivers live in /Library, and restarts the system audio service so it loads.
@Observable @MainActor
final class StreamDevice {
    enum State: Equatable {
        case notInstalled
        case outdated
        case installed
        case working
        case failed(String)
    }

    static let deviceUID = "DJI Controller_UID"
    static let installPath = "/Library/Audio/Plug-Ins/HAL/DJIControllerStream.driver"

    private(set) var state: State = .notInstalled
    /// Called once the device is visible after a successful install.
    var onInstalled: (() -> Void)?

    private let log = Logger(subsystem: "com.sauerdev.djicontroller", category: "stream-device")

    init() {
        refresh()
    }

    var needsSetup: Bool { state == .notInstalled || state == .outdated }

    func refresh() {
        guard FileManager.default.fileExists(atPath: Self.installPath) else {
            state = .notInstalled
            return
        }
        let bundled = bundledURL.flatMap { Self.version(at: $0.path) }
        state = bundled != nil && Self.version(at: Self.installPath) != bundled ? .outdated : .installed
    }

    func install() {
        guard let source = bundledURL?.path else {
            state = .failed("The stream device is missing from the app. Rebuild DJI Controller.")
            return
        }
        let target = Self.quoted(Self.installPath)
        runPrivileged("""
            /bin/mkdir -p /Library/Audio/Plug-Ins/HAL && \
            /bin/rm -rf \(target) && \
            /usr/bin/ditto \(Self.quoted(source)) \(target) && \
            /usr/sbin/chown -R root:wheel \(target) && \
            /usr/bin/find \(target) -type d -exec /bin/chmod 755 {} + && \
            /usr/bin/find \(target) -type f -exec /bin/chmod 644 {} + && \
            /bin/chmod 755 \(target)/Contents/MacOS/* && \
            /usr/bin/killall coreaudiod
            """, success: true)
    }

    func remove() {
        runPrivileged("/bin/rm -rf \(Self.quoted(Self.installPath)) && /usr/bin/killall coreaudiod", success: false)
    }

    private var bundledURL: URL? {
        Bundle.main.url(forResource: "DJIControllerStream", withExtension: "driver")
    }

    private func runPrivileged(_ command: String, success installing: Bool) {
        state = .working
        // Let the UI show "Setting up" before the system password dialog appears.
        DispatchQueue.main.async {
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            var error: NSDictionary?
            NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
            if let error {
                let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                self.log.error("privileged command failed (\(code)): \(message, privacy: .public)")
                self.refresh()
                if code != -128 { // -128: the user cancelled the password dialog
                    self.state = .failed(installing ? "Setup failed: \(message)" : "Couldn't remove it: \(message)")
                }
                return
            }
            self.refresh()
            if installing { self.waitForDevice() }
        }
    }

    /// The audio service takes a moment to come back after the restart.
    private func waitForDevice() {
        Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                if CoreAudioHAL.devices().contains(where: { $0.uid == Self.deviceUID }) {
                    log.info("stream device is live")
                    onInstalled?()
                    return
                }
            }
            state = .failed("The stream device was installed but didn't appear. Restart the Mac to load it.")
        }
    }

    private static func version(at path: String) -> String? {
        NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleVersion"] as? String
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
