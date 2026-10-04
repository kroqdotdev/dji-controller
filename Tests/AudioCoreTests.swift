import AudioToolbox
import Testing
@testable import Lavboard

/// Drives the real-time IOProc with synthetic buffers: 4 input channels, a venue and a stream output.
final class CoreHarness {
    let core: OpaquePointer
    let frames: Int

    init(ringFrames: UInt32 = 1 << 12, frames: Int = 64) {
        core = AudioCoreCreate(ringFrames)
        self.frames = frames
        AudioCoreSetLayout(core, 0, 4, 0, 1)
    }

    deinit { AudioCoreDestroy(core) }

    /// Runs one IO cycle with a constant value per input channel; returns venue and stream left channel.
    @discardableResult
    func cycle(_ input: [Float]) -> (venue: [Float], stream: [Float]) {
        var inData = [Float](repeating: 0, count: frames * 4)
        for f in 0..<frames { for c in 0..<4 { inData[f * 4 + c] = input[c] } }
        var venue = [Float](repeating: 9, count: frames * 2)
        var stream = [Float](repeating: 9, count: frames * 2)
        let inList = AudioBufferList.allocate(maximumBuffers: 1)
        let outList = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(inList.unsafeMutablePointer); free(outList.unsafeMutablePointer) }
        var ts = AudioTimeStamp()
        inData.withUnsafeMutableBytes { inRaw in
            venue.withUnsafeMutableBytes { vRaw in
                stream.withUnsafeMutableBytes { sRaw in
                    inList[0] = AudioBuffer(mNumberChannels: 4, mDataByteSize: UInt32(inRaw.count), mData: inRaw.baseAddress)
                    outList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(vRaw.count), mData: vRaw.baseAddress)
                    outList[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(sRaw.count), mData: sRaw.baseAddress)
                    _ = AudioCoreIOProc(0, &ts, inList.unsafePointer, &ts, outList.unsafeMutablePointer, &ts,
                                        UnsafeMutableRawPointer(core))
                }
            }
        }
        return (stride(from: 0, to: venue.count, by: 2).map { venue[$0] },
                stride(from: 0, to: stream.count, by: 2).map { stream[$0] })
    }
}

struct AudioCoreTests {
    let input: [Float] = [0.1, 0.2, 0.3, 0.0]

    @Test func mixesAllChannelsAtUnityAfterRamp() {
        let h = CoreHarness()
        h.cycle(input)
        let out = h.cycle(input)
        #expect(out.stream.allSatisfy { abs($0 - 0.6) < 1e-5 })
        #expect(out.venue.allSatisfy { abs($0 - 0.6) < 1e-5 })
    }

    @Test func muteRemovesOnlyThatChannelFromBothMixes() {
        let h = CoreHarness()
        h.cycle(input)
        AudioCoreSetChannelMute(h.core, 1, true)
        h.cycle(input) // ramp buffer
        let out = h.cycle(input)
        #expect(out.stream.allSatisfy { abs($0 - 0.4) < 1e-5 })
        #expect(out.venue.allSatisfy { abs($0 - 0.4) < 1e-5 })
    }

    @Test func muteRampsWithinOneBuffer() {
        let h = CoreHarness()
        h.cycle(input)
        h.cycle(input)
        AudioCoreSetChannelMute(h.core, 2, true)
        let ramp = h.cycle(input).stream
        #expect(ramp.first! > ramp.last!)
        #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 >= $1 - 1e-6 })
        #expect(abs(ramp.last! - 0.3) < 1e-4)
    }

    @Test func venueSendOffKeepsChannelInStreamOnly() {
        let h = CoreHarness()
        AudioCoreSetChannelVenueSend(h.core, 0, false)
        h.cycle(input)
        let out = h.cycle(input)
        #expect(out.stream.allSatisfy { abs($0 - 0.6) < 1e-5 })
        #expect(out.venue.allSatisfy { abs($0 - 0.5) < 1e-5 })
    }

    @Test func faderGainAndOutputLevelsScale() {
        let h = CoreHarness()
        AudioCoreSetChannelGain(h.core, 2, 0.5)
        AudioCoreSetStreamLevel(h.core, 0.5)
        h.cycle(input)
        let out = h.cycle(input)
        #expect(out.stream.allSatisfy { abs($0 - 0.225) < 1e-5 })
        #expect(out.venue.allSatisfy { abs($0 - 0.45) < 1e-5 })
    }

    @Test func metersReportPreFaderPeaks() {
        let h = CoreHarness()
        AudioCoreSetChannelMute(h.core, 0, true)
        h.cycle(input)
        var m = AudioCoreMeters()
        AudioCoreReadMeters(h.core, &m)
        #expect(abs(m.peak.0 - 0.1) < 1e-6)
        #expect(abs(m.peak.2 - 0.3) < 1e-6)
        #expect(m.callbacks == 1)
        AudioCoreReadMeters(h.core, &m)
        #expect(m.peak.0 == 0)
    }

    @Test func recordsRawTracksEvenWhenMuted() {
        let h = CoreHarness()
        h.cycle(input)
        AudioCoreSetChannelMute(h.core, 1, true)
        AudioCoreStartRecording(h.core)
        h.cycle(input)
        h.cycle(input)
        AudioCoreStopRecording(h.core)
        h.cycle(input) // not recorded
        var buffer = [Float](repeating: 0, count: 1024 * Int(AC_RING_CHANNELS))
        let frames = buffer.withUnsafeMutableBufferPointer { AudioCoreReadRecorded(h.core, $0.baseAddress!, 1024) }
        #expect(frames == 128)
        let last = Array(buffer[(127 * 6)..<(128 * 6)])
        #expect(abs(last[1] - 0.2) < 1e-6) // raw track keeps the muted mic
        #expect(abs(last[4] - 0.4) < 1e-5) // mix reflects the mute
    }

    @Test func countsOverrunWhenDiskFallsBehind() {
        let h = CoreHarness(ringFrames: 128)
        AudioCoreStartRecording(h.core)
        for _ in 0..<3 { h.cycle(input) }
        var m = AudioCoreMeters()
        AudioCoreReadMeters(h.core, &m)
        #expect(m.overruns == 1)
    }
}
