import Foundation
import Observation

/// Display levels for every meter, refreshed 30 times a second from the audio core. Meter views
/// read their own entry, so only they redraw.
@Observable @MainActor
final class MeterStore {
    /// Instant attack, 24 dB/s release, a 1.5 s peak hold and a 2 s clip latch.
    struct Level: Equatable {
        var level: Float = -120
        var hold: Float = -120
        fileprivate var holdUntil = Date.distantPast
        fileprivate var clipUntil = Date.distantPast
        var clipping: Bool { clipUntil > Date() }

        fileprivate mutating func feed(_ peak: Float, dt: Float, now: Date) {
            let db = peak > 0 ? 20 * log10(peak) : -120
            level = max(db, level - 24 * dt)
            if db >= hold || now > holdUntil {
                hold = max(db, hold - 24 * dt)
                if db >= hold { holdUntil = now.addingTimeInterval(1.5) }
            }
            if peak >= 0.999 { clipUntil = now.addingTimeInterval(2) }
        }
    }

    struct TrackLevels: Equatable {
        var left = Level()
        var right = Level()
    }

    private(set) var tracks = [TrackLevels](repeating: TrackLevels(), count: Int(AC_MAX_TRACKS))
    private(set) var stream = Level()
    private(set) var venue = Level()

    @ObservationIgnored private var last = Date()

    func update(_ meters: AudioCoreMeters, now: Date = Date()) {
        let dt = Float(min(now.timeIntervalSince(last), 0.25))
        last = now
        let left = withUnsafeBytes(of: meters.peakLeft) { Array($0.bindMemory(to: Float.self)) }
        let right = withUnsafeBytes(of: meters.peakRight) { Array($0.bindMemory(to: Float.self)) }
        var next = tracks
        for i in next.indices {
            next[i].left.feed(left[i], dt: dt, now: now)
            next[i].right.feed(right[i], dt: dt, now: now)
        }
        tracks = next
        stream.feed(meters.streamPeak, dt: dt, now: now)
        venue.feed(meters.venuePeak, dt: dt, now: now)
    }
}
