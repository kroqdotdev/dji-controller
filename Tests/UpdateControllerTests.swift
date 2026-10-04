import Sparkle
import Testing
@testable import Lavboard

/// The restart step is the one place an update can interrupt a show, so it is tested directly.
@MainActor
struct UpdateControllerTests {
    @Test func restartsStraightAwayWhenNotRecording() {
        let updates = UpdateController()
        updates.shouldDeferRestart = { false }
        var choice: SPUUserUpdateChoice?
        updates.showReady(toInstallAndRelaunch: { choice = $0 })
        #expect(choice == .install)
        #expect(updates.state == .installing)
    }

    @Test func holdsRestartWhileRecordingUntilAsked() {
        let updates = UpdateController()
        updates.shouldDeferRestart = { true }
        var choice: SPUUserUpdateChoice?
        updates.showReady(toInstallAndRelaunch: { choice = $0 })
        #expect(choice == nil)
        #expect(updates.state == .readyToRestart)

        updates.restartNow()
        #expect(choice == .install)
        #expect(updates.state == .installing)
    }

    @Test func blocksRecordingWhileDownloadingOrInstalling() {
        let updates = UpdateController()
        updates.showDownloadInitiated(cancellation: {})
        #expect(updates.isBusy)
        updates.showDownloadDidStartExtractingUpdate()
        #expect(updates.isBusy)
        updates.dismissUpdateInstallation()
        #expect(!updates.isBusy)
        #expect(updates.state == .idle)
    }

    @Test func reportsDownloadProgress() {
        let updates = UpdateController()
        updates.showDownloadInitiated(cancellation: {})
        updates.showDownloadDidReceiveExpectedContentLength(1000)
        updates.showDownloadDidReceiveData(ofLength: 250)
        #expect(updates.state == .downloading(fraction: 0.25))
    }
}
