import CoreAudio
import Testing
@testable import Lavboard

struct AppAudioTests {
    @Test func appTapsMixDownOnlyThatAppsProcesses() {
        let tap = TapSpec(identity: "app#com.spotify.client", name: "Spotify", global: false, processes: [41, 42]).description()
        #expect(tap.processes == [41, 42])
        #expect(!tap.isExclusive) // the listed processes are the ones captured
        #expect(tap.isMixdown && !tap.isMono)
    }

    @Test func systemAudioCapturesEverythingButTheExcludedProcesses() {
        let tap = TapSpec(identity: "system-audio", name: "Mac audio", global: true, processes: [7]).description()
        #expect(tap.processes == [7])
        #expect(tap.isExclusive) // the listed processes are left out
        #expect(tap.isMixdown && !tap.isMono)
    }

    @Test func tapsNeverSilenceTheAppTheyRecord() {
        let tap = TapSpec(identity: "app#x", name: "X", global: false, processes: []).description()
        #expect(tap.muteBehavior == .unmuted)
        #expect(tap.isPrivate)
    }

    @Test func streamingAppsAreKeptOutOfMacAudio() {
        #expect(AppAudio.streamingApps.contains("com.obsproject.obs-studio"))
        #expect(AppAudio.streamingApps.contains("com.streamlabs.slobs"))
    }
}
