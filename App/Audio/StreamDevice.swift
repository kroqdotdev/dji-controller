import AppKit
import Foundation
import Observation
import Security
import os

/// Installs the bundled "Lavboard" virtual audio device (built from BlackHole) so
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

    static let deviceUID = "Lavboard_UID"
    static let installPath = "/Library/Audio/Plug-Ins/HAL/LavboardStream.driver"
    /// Installed by builds from before the app was renamed to Lavboard; removed on install.
    static let legacyInstallPath = "/Library/Audio/Plug-Ins/HAL/DJIControllerStream.driver"

    private(set) var state: State = .notInstalled
    /// Called once the device is visible after a successful install.
    var onInstalled: (() -> Void)?

    private let log = Logger(subsystem: "com.sauerdev.lavboard", category: "stream-device")

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
            state = .failed("The stream device is missing from the app. Rebuild Lavboard.")
            return
        }
        // The app bundle may live somewhere the user (or anything running as the user) can
        // write to. So the root script copies the driver into a fresh root-only folder first,
        // checks the copy's signature there, and only then moves it into place.
        let target = Self.quoted(Self.installPath)
        runPrivileged("""
            set -e; \
            staging=$(/usr/bin/mktemp -d /tmp/lavboard-driver.XXXXXX); \
            trap '/bin/rm -rf "$staging"' EXIT; \
            /usr/bin/ditto \(Self.quoted(source)) "$staging/LavboardStream.driver"; \
            /usr/bin/codesign --verify --strict -R=\(Self.quoted(Self.signingRequirement)) "$staging/LavboardStream.driver"; \
            /usr/sbin/chown -R root:wheel "$staging/LavboardStream.driver"; \
            /usr/bin/find "$staging/LavboardStream.driver" -type d -exec /bin/chmod 755 {} +; \
            /usr/bin/find "$staging/LavboardStream.driver" -type f -exec /bin/chmod 644 {} +; \
            /bin/chmod 755 "$staging/LavboardStream.driver/Contents/MacOS/"*; \
            /bin/mkdir -p /Library/Audio/Plug-Ins/HAL; \
            /bin/rm -rf \(target) \(Self.quoted(Self.legacyInstallPath)); \
            /bin/mv "$staging/LavboardStream.driver" \(target); \
            /usr/bin/killall coreaudiod
            """, success: true)
    }

    /// The driver must carry our identifier and, when the app is signed by a team, that same team.
    /// Ad-hoc builds have no team to anchor to, so only the identifier can be checked.
    private static var signingRequirement: String {
        let identifier = "identifier \"com.sauerdev.lavboard.stream\""
        guard let team = runningTeamID else { return identifier }
        return identifier + " and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    private static var runningTeamID: String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    func remove() {
        runPrivileged("/bin/rm -rf \(Self.quoted(Self.installPath)) \(Self.quoted(Self.legacyInstallPath)) && /usr/bin/killall coreaudiod", success: false)
    }

    private var bundledURL: URL? {
        Bundle.main.url(forResource: "LavboardStream", withExtension: "driver")
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
