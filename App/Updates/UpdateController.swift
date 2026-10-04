import Foundation
import Observation
import Sparkle
import os

/// Checks for a new release on every launch and installs it with one click. Sparkle does the
/// work (feed, EdDSA and code signature checks, installation, relaunch); this class replaces
/// Sparkle's dialogs with Lavboard's own toolbar button.
@Observable @MainActor
final class UpdateController: NSObject {
    enum State: Equatable {
        case idle
        case checking
        case available(version: String)
        case downloading(fraction: Double?)
        case installing
        /// Downloaded and verified, waiting for a recording to stop before restarting.
        case readyToRestart
        case upToDate
        case failed(String)
    }

    private(set) var state: State = .idle
    /// True while an update is downloading or installing; recording is blocked meanwhile.
    var isBusy: Bool {
        switch state {
        case .downloading, .installing: true
        default: false
        }
    }
    /// Asked right before the app restarts; return true to hold the restart (e.g. while recording).
    @ObservationIgnored var shouldDeferRestart: (() -> Bool)?
    var feedURL: String { updater?.feedURL?.absoluteString ?? "" }
    /// Underlying cause of the last failure, for diagnostics.
    @ObservationIgnored private(set) var lastErrorDetail = ""

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var pendingRestart: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var expectedBytes: UInt64 = 0
    @ObservationIgnored private var receivedBytes: UInt64 = 0
    @ObservationIgnored private let log = Logger(subsystem: "com.sauerdev.lavboard", category: "updates")

    func start() {
        #if DEBUG
        // Debug builds have their own bundle identifier, and Sparkle can't replace an app with one
        // that has another identifier, so they only check a local test feed (see CONTRIBUTING).
        guard UserDefaults.standard.string(forKey: "LavboardTestFeedURL") != nil else {
            log.info("debug build: update checks are off without LavboardTestFeedURL")
            return
        }
        #endif
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
            self.updater = updater
            updater.checkForUpdatesInBackground()
        } catch {
            log.error("updater failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Downloads, installs and relaunches. Called when the user clicks the update button.
    func install() {
        guard let reply = pendingChoice else { return }
        pendingChoice = nil
        expectedBytes = 0
        receivedBytes = 0
        state = .downloading(fraction: nil)
        reply(.install)
    }

    /// Restarts into an update that was held back while recording.
    func restartNow() {
        guard let reply = pendingRestart else { return }
        pendingRestart = nil
        state = .installing
        reply(.install)
    }

    /// A user-initiated check (menu item, or retry after a failure).
    func checkNow() {
        #if DEBUG
        if updater == nil {
            state = .failed("Debug builds only check a local test feed (LavboardTestFeedURL).")
            return
        }
        #endif
        guard let updater, updater.canCheckForUpdates else { return }
        state = .checking
        updater.checkForUpdates()
    }

    private func showTransient(_ transient: State) {
        state = transient
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if self.state == transient { self.state = .idle }
        }
    }
}

// Sparkle calls the user driver on the main thread.
extension UpdateController: SPUUserDriver {
    nonisolated func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Automatic checks are enabled in Info.plist, so this is only a fallback.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    nonisolated func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        MainActor.assumeIsolated { state = .checking }
    }

    nonisolated func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        MainActor.assumeIsolated {
            // Keep the reply until the user clicks the button; Sparkle waits for it.
            pendingChoice = reply
            self.state = .available(version: appcastItem.displayVersionString)
            log.info("update available: \(appcastItem.displayVersionString, privacy: .public)")
        }
    }

    nonisolated func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    nonisolated func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    nonisolated func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        MainActor.assumeIsolated {
            if state == .checking { showTransient(.upToDate) }
            acknowledgement()
        }
    }

    nonisolated func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        MainActor.assumeIsolated {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey].map { "\($0)" } ?? "none"
            log.error("update failed: \(error.localizedDescription, privacy: .public) underlying: \(underlying, privacy: .public)")
            lastErrorDetail = underlying
            pendingChoice = nil
            state = .failed(error.localizedDescription)
            acknowledgement()
        }
    }

    nonisolated func showDownloadInitiated(cancellation: @escaping () -> Void) {
        MainActor.assumeIsolated { state = .downloading(fraction: 0) }
    }

    nonisolated func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        MainActor.assumeIsolated { expectedBytes = expectedContentLength }
    }

    nonisolated func showDownloadDidReceiveData(ofLength length: UInt64) {
        MainActor.assumeIsolated {
            receivedBytes += length
            let fraction = expectedBytes > 0 ? min(1, Double(receivedBytes) / Double(expectedBytes)) : nil
            state = .downloading(fraction: fraction)
        }
    }

    nonisolated func showDownloadDidStartExtractingUpdate() {
        MainActor.assumeIsolated { state = .installing }
    }

    nonisolated func showExtractionReceivedProgress(_ progress: Double) {}

    nonisolated func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        MainActor.assumeIsolated {
            // The user already chose to install when they clicked the button, but never restart
            // in the middle of a recording: hold it until the recording stops.
            if shouldDeferRestart?() == true {
                pendingRestart = reply
                state = .readyToRestart
            } else {
                state = .installing
                reply(.install)
            }
        }
    }

    nonisolated func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        MainActor.assumeIsolated { state = .installing }
    }

    nonisolated func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    nonisolated func showUpdateInFocus() {}

    nonisolated func dismissUpdateInstallation() {
        MainActor.assumeIsolated {
            switch state {
            case .checking, .downloading, .installing, .readyToRestart:
                pendingRestart = nil
                state = .idle
            default: break
            }
        }
    }
}

extension UpdateController: SPUUpdaterDelegate {
    #if DEBUG
    /// Debug builds can point at a local test feed: defaults write com.sauerdev.lavboard.debug LavboardTestFeedURL <url>
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "LavboardTestFeedURL")
    }
    #endif
}
