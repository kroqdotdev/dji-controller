import Foundation
import os

/// Per-track mixer settings (fader, mute, venue send, balance), written to the audio core by each
/// track's position in the layout that is actually running.
///
/// Positions change as soon as tracks are moved or removed, but the new layout only starts once
/// the engine has rebuilt. Keying settings by track, and switching positions in the same step that
/// installs the layout, keeps a muted mic muted through that gap. Safe to call from any thread.
final class TrackControls: @unchecked Sendable {
    struct Settings: Equatable {
        var gainDB: Double
        var muted: Bool
        var venueSend: Bool
        var balance: Double

        /// For a track that has been removed but is still in the running layout.
        static let silent = Settings(gainDB: -60, muted: true, venueSend: false, balance: 0)
    }

    private struct State {
        var settings: [UUID: Settings] = [:]
        /// The track at each position of the running layout.
        var installed: [UUID] = []
    }

    private let core: OpaquePointer
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(core: OpaquePointer) {
        self.core = core
    }

    /// The app's current settings for every track.
    func update(_ settings: [UUID: Settings]) {
        state.withLock { s in
            s.settings = settings
            write(s)
        }
    }

    /// Called by the engine as it installs a layout, before the mixer starts running it.
    func install(_ trackIDs: [UUID]) {
        state.withLock { s in
            s.installed = trackIDs
            write(s)
        }
    }

    private func write(_ s: State) {
        for (i, id) in s.installed.enumerated() {
            let t = s.settings[id] ?? .silent
            let index = Int32(i)
            AudioCoreSetTrackGain(core, index, AudioEngine.linear(t.gainDB))
            AudioCoreSetTrackMute(core, index, t.muted)
            AudioCoreSetTrackVenueSend(core, index, t.venueSend)
            AudioCoreSetTrackBalance(core, index, Float(t.balance))
        }
    }
}
