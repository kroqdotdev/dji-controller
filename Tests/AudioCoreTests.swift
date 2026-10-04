import AudioToolbox
import Testing
@testable import Lavboard

/// Drives the real-time IOProc with synthetic buffers: a 4-channel "receiver" input buffer, a
/// 2-channel "USB device" input buffer, and stereo venue and stream outputs.
final class CoreHarness {
    let core: OpaquePointer
    let frames: Int

    init(ringFrames: UInt32 = 1 << 12, frames: Int = 64, tracks: [AudioCoreTrackLayout] = CoreHarness.fourMono) {
        core = AudioCoreCreate(ringFrames)
        self.frames = frames
        tracks.withUnsafeBufferPointer { AudioCoreSetLayout(core, $0.baseAddress, Int32(tracks.count), 0, 1) }
    }

    deinit { AudioCoreDestroy(core) }

    static func mono(_ buffer: Int32, _ channel: Int32) -> AudioCoreTrackLayout {
        AudioCoreTrackLayout(buffer: buffer, channel: channel, bufferRight: -1, channelRight: -1, stereo: false, asyncSource: -1)
    }

    static func stereo(_ buffer: Int32, _ left: Int32, _ right: Int32) -> AudioCoreTrackLayout {
        AudioCoreTrackLayout(buffer: buffer, channel: left, bufferRight: buffer, channelRight: right, stereo: true, asyncSource: -1)
    }

    static let fourMono = (0..<4).map { mono(0, Int32($0)) }

    struct Output {
        var venue: [(left: Float, right: Float)]
        var stream: [(left: Float, right: Float)]
    }

    /// One IO cycle with constant values: `receiver` feeds input buffer 0, `usb` feeds buffer 1.
    @discardableResult
    func cycle(receiver: [Float] = [0.1, 0.2, 0.3, 0.0], usb: [Float] = [0.0, 0.0]) -> Output {
        var rx = [Float](repeating: 0, count: frames * 4)
        var dev = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            for c in 0..<4 { rx[f * 4 + c] = receiver[c] }
            for c in 0..<2 { dev[f * 2 + c] = usb[c] }
        }
        var venue = [Float](repeating: 9, count: frames * 2)
        var stream = [Float](repeating: 9, count: frames * 2)
        let inList = AudioBufferList.allocate(maximumBuffers: 2)
        let outList = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(inList.unsafeMutablePointer); free(outList.unsafeMutablePointer) }
        var ts = AudioTimeStamp()
        rx.withUnsafeMutableBytes { rxRaw in
            dev.withUnsafeMutableBytes { devRaw in
                venue.withUnsafeMutableBytes { vRaw in
                    stream.withUnsafeMutableBytes { sRaw in
                        inList[0] = AudioBuffer(mNumberChannels: 4, mDataByteSize: UInt32(rxRaw.count), mData: rxRaw.baseAddress)
                        inList[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(devRaw.count), mData: devRaw.baseAddress)
                        outList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(vRaw.count), mData: vRaw.baseAddress)
                        outList[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(sRaw.count), mData: sRaw.baseAddress)
                        _ = AudioCoreIOProc(0, &ts, inList.unsafePointer, &ts, outList.unsafeMutablePointer, &ts,
                                            UnsafeMutableRawPointer(core))
                    }
                }
            }
        }
        func pairs(_ a: [Float]) -> [(left: Float, right: Float)] {
            stride(from: 0, to: a.count, by: 2).map { (a[$0], a[$0 + 1]) }
        }
        return Output(venue: pairs(venue), stream: pairs(stream))
    }
}

func all(_ samples: [(left: Float, right: Float)], left: Float, right: Float) -> Bool {
    samples.allSatisfy { abs($0.left - left) < 1e-5 && abs($0.right - right) < 1e-5 }
}

struct AudioCoreTests {
    @Test func monoTracksMixToTheCentreOfBothOutputs() {
        let h = CoreHarness()
        h.cycle()
        let out = h.cycle()
        #expect(all(out.stream, left: 0.6, right: 0.6))
        #expect(all(out.venue, left: 0.6, right: 0.6))
    }

    @Test func muteRemovesOnlyThatTrackFromBothMixes() {
        let h = CoreHarness()
        h.cycle()
        AudioCoreSetTrackMute(h.core, 1, true)
        h.cycle()
        let out = h.cycle()
        #expect(all(out.stream, left: 0.4, right: 0.4))
        #expect(all(out.venue, left: 0.4, right: 0.4))
    }

    @Test func muteRampsWithinOneBuffer() {
        let h = CoreHarness()
        h.cycle()
        h.cycle()
        AudioCoreSetTrackMute(h.core, 2, true)
        let ramp = h.cycle().stream.map(\.left)
        #expect(ramp.first! > ramp.last!)
        #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 >= $1 - 1e-6 })
        #expect(abs(ramp.last! - 0.3) < 1e-4)
    }

    @Test func venueSendOffKeepsTrackInStreamOnly() {
        let h = CoreHarness()
        AudioCoreSetTrackVenueSend(h.core, 0, false)
        h.cycle()
        let out = h.cycle()
        #expect(all(out.stream, left: 0.6, right: 0.6))
        #expect(all(out.venue, left: 0.5, right: 0.5))
    }

    @Test func faderGainAndOutputLevelsScale() {
        let h = CoreHarness()
        AudioCoreSetTrackGain(h.core, 2, 0.5)
        AudioCoreSetStreamLevel(h.core, 0.5)
        h.cycle()
        let out = h.cycle()
        #expect(all(out.stream, left: 0.225, right: 0.225))
        #expect(all(out.venue, left: 0.45, right: 0.45))
    }

    @Test func stereoTrackKeepsItsSidesAndHonoursBalance() {
        let h = CoreHarness(tracks: [CoreHarness.stereo(1, 0, 1)])
        let usb: [Float] = [0.2, 0.4]
        h.cycle(usb: usb)
        #expect(all(h.cycle(usb: usb).stream, left: 0.2, right: 0.4))

        AudioCoreSetTrackBalance(h.core, 0, 1)
        h.cycle(usb: usb)
        #expect(all(h.cycle(usb: usb).stream, left: 0, right: 0.4))

        AudioCoreSetTrackBalance(h.core, 0, -0.5)
        h.cycle(usb: usb)
        #expect(all(h.cycle(usb: usb).stream, left: 0.2, right: 0.2))
    }

    @Test func tracksFromDifferentDevicesMixTogether() {
        let h = CoreHarness(tracks: [CoreHarness.mono(0, 0), CoreHarness.mono(1, 1)])
        h.cycle(usb: [0.0, 0.25])
        #expect(all(h.cycle(usb: [0.0, 0.25]).stream, left: 0.35, right: 0.35))
    }

    @Test func missingSourceIsSilentWithoutDisturbingOthers() {
        let h = CoreHarness(tracks: [CoreHarness.mono(0, 0), CoreHarness.mono(5, 0), CoreHarness.mono(1, 7)])
        h.cycle()
        #expect(all(h.cycle().stream, left: 0.1, right: 0.1))
    }

    @Test func metersReportPreFaderPeaksPerSide() {
        let h = CoreHarness(tracks: [CoreHarness.mono(0, 0), CoreHarness.stereo(1, 0, 1)])
        AudioCoreSetTrackMute(h.core, 0, true)
        h.cycle(usb: [0.2, 0.4])
        var m = AudioCoreMeters()
        AudioCoreReadMeters(h.core, &m)
        #expect(abs(m.peakLeft.0 - 0.1) < 1e-6)
        #expect(abs(m.peakLeft.1 - 0.2) < 1e-6)
        #expect(abs(m.peakRight.1 - 0.4) < 1e-6)
        #expect(m.callbacks == 1)
        AudioCoreReadMeters(h.core, &m)
        #expect(m.peakLeft.0 == 0)
    }

    @Test func recordsEachTracksChannelsThenTheMix() {
        let h = CoreHarness(tracks: [CoreHarness.mono(0, 1), CoreHarness.stereo(1, 0, 1)])
        #expect(AudioCoreRingChannels(h.core) == 5)
        let usb: [Float] = [0.25, 0.5]
        h.cycle(usb: usb)
        AudioCoreSetTrackMute(h.core, 0, true)
        AudioCoreStartRecording(h.core)
        h.cycle(usb: usb)
        h.cycle(usb: usb)
        AudioCoreStopRecording(h.core)
        h.cycle(usb: usb)
        var buffer = [Float](repeating: 0, count: 1024 * (Int(AC_MAX_TRACKS) * 2 + 2))
        let frames = buffer.withUnsafeMutableBufferPointer { AudioCoreReadRecorded(h.core, $0.baseAddress!, 1024) }
        #expect(frames == 128)
        let last = Array(buffer[(127 * 5)..<(128 * 5)])
        #expect(abs(last[0] - 0.2) < 1e-6)  // mono track, raw even though muted
        #expect(abs(last[1] - 0.25) < 1e-6) // stereo track left
        #expect(abs(last[2] - 0.5) < 1e-6)  // stereo track right
        #expect(abs(last[3] - 0.25) < 1e-5) // mix left reflects the mute
        #expect(abs(last[4] - 0.5) < 1e-5)  // mix right
    }

    @Test func countsOverrunWhenDiskFallsBehind() {
        let h = CoreHarness(ringFrames: 128)
        AudioCoreStartRecording(h.core)
        for _ in 0..<3 { h.cycle() }
        var m = AudioCoreMeters()
        AudioCoreReadMeters(h.core, &m)
        #expect(m.overruns == 1)
    }

    @Test func layoutIsCappedAtEightTracks() {
        let many = (0..<12).map { CoreHarness.mono(0, Int32($0 % 4)) }
        let h = CoreHarness(tracks: many)
        #expect(AudioCoreTrackCount(h.core) == 8)
        #expect(AudioCoreRingChannels(h.core) == 10)
    }
}
