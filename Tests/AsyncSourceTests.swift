import AudioToolbox
import Foundation
import Testing
@testable import Lavboard

/// Simulates a device on its own clock feeding an async source while the mixer renders it.
final class AsyncHarness {
    let source: OpaquePointer
    let sourceRate: Double
    let targetRate: Double
    let channels: Int
    /// Device clock speed relative to nominal: 1.001 delivers 0.1% more frames per second.
    var drift = 1.0
    var chunk: Int
    var producing = true
    /// Generates the sample for channel `c` at source frame `n`.
    var signal: (_ n: Int, _ c: Int) -> Float

    private var produced = 0
    private var producerTime = 0.0
    private var consumerTime = 0.0

    init(sourceRate: Double, targetRate: Double = 48_000, channels: Int = 1, latency: UInt32 = 256, chunk: Int = 160,
         signal: @escaping (_ n: Int, _ c: Int) -> Float) {
        source = AudioCoreAsyncCreate(Int32(channels), sourceRate, targetRate, latency)!
        self.sourceRate = sourceRate
        self.targetRate = targetRate
        self.channels = channels
        self.chunk = chunk
        self.signal = signal
    }

    deinit { AudioCoreAsyncDestroy(source) }

    /// Delivers device chunks until the producer has caught up with the mixer's clock.
    func produce() {
        while producing && producerTime <= consumerTime {
            var data = [Float](repeating: 0, count: chunk * channels)
            for f in 0..<chunk { for c in 0..<channels { data[f * channels + c] = signal(produced + f, c) } }
            AsyncHarness.deliver(data, channels: channels, to: source)
            produced += chunk
            producerTime += Double(chunk) / (sourceRate * drift)
        }
    }

    /// One mixer cycle: returns `frames` rendered frames per channel.
    @discardableResult
    func render(_ frames: Int = 64) -> [[Float]] {
        consumerTime += Double(frames) / targetRate
        produce()
        AudioCoreAsyncRender(source, UInt32(frames))
        return (0..<channels).map { c in Array(UnsafeBufferPointer(start: AudioCoreAsyncOutput(source, Int32(c))!, count: frames)) }
    }

    func run(seconds: Double, frames: Int = 64) -> [[Float]] {
        var out = [[Float]](repeating: [], count: channels)
        for _ in 0..<Int(seconds * targetRate / Double(frames)) {
            for (c, samples) in render(frames).enumerated() { out[c] += samples }
        }
        return out
    }

    /// Runs without keeping the output, to let the drift controller settle.
    func settle(seconds: Double, frames: Int = 64) {
        for _ in 0..<Int(seconds * targetRate / Double(frames)) {
            consumerTime += Double(frames) / targetRate
            produce()
            AudioCoreAsyncRender(source, UInt32(frames))
        }
    }

    var stats: AudioCoreAsyncStats {
        var s = AudioCoreAsyncStats()
        AudioCoreAsyncReadStats(source, &s)
        return s
    }

    static func deliver(_ interleaved: [Float], channels: Int, to source: OpaquePointer) {
        var data = interleaved
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        var ts = AudioTimeStamp()
        var noOutput = AudioBufferList()
        noOutput.mNumberBuffers = 0
        data.withUnsafeMutableBytes { raw in
            list[0] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
            _ = AudioCoreAsyncIOProc(0, &ts, list.unsafePointer, &ts, &noOutput, &ts, UnsafeMutableRawPointer(source))
        }
    }
}

private func sine(_ hz: Double, rate: Double, amplitude: Float = 0.5) -> (Int, Int) -> Float {
    { n, _ in amplitude * Float(sin(2 * .pi * hz * Double(n) / rate)) }
}

/// Frequency from rising zero crossings, with linear interpolation between samples.
private func frequency(_ x: [Float], rate: Double) -> Double {
    var crossings: [Double] = []
    for i in 1..<x.count where x[i - 1] < 0 && x[i] >= 0 {
        crossings.append(Double(i - 1) + Double(-x[i - 1] / (x[i] - x[i - 1])))
    }
    guard let first = crossings.first, let last = crossings.last, crossings.count > 1 else { return 0 }
    return Double(crossings.count - 1) / ((last - first) / rate)
}

private func rms(_ x: [Float]) -> Float {
    sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1)))
}

struct AsyncSourceTests {
    @Test func upsamplesAToneWithoutChangingPitchOrLevel() {
        let h = AsyncHarness(sourceRate: 16_000, signal: sine(1_000, rate: 16_000))
        h.settle(seconds: 1)
        let out = h.run(seconds: 1)[0]
        #expect(abs(frequency(out, rate: 48_000) - 1_000) < 1)
        #expect(abs(rms(out) - 0.5 / sqrt(2)) < 0.005)
        #expect(h.stats.underruns == 0 && h.stats.overflows == 0)
    }

    @Test func downsamplesWithoutAliasing() {
        // 1 kHz passes; 30 kHz is above the 24 kHz output Nyquist and must not fold back to 18 kHz.
        let pass = AsyncHarness(sourceRate: 96_000, latency: 2_048, chunk: 960, signal: sine(1_000, rate: 96_000))
        pass.settle(seconds: 0.5)
        let passOut = pass.run(seconds: 0.5)[0]
        #expect(abs(frequency(passOut, rate: 48_000) - 1_000) < 1)
        #expect(abs(rms(passOut) - 0.5 / sqrt(2)) < 0.005)
        #expect(pass.stats.underruns == 0)

        let stop = AsyncHarness(sourceRate: 96_000, latency: 2_048, chunk: 960, signal: sine(30_000, rate: 96_000))
        stop.settle(seconds: 0.5)
        let stopOut = stop.run(seconds: 0.5)[0]
        #expect(rms(stopOut) < 0.5 / sqrt(2) * 0.001) // at least 60 dB down
        #expect(stop.stats.running && stop.stats.underruns == 0)
    }

    @Test func followsADriftingDeviceClock() {
        for drift in [1.001, 0.9995] {
            // 512-frame device chunks need more than half a chunk of headroom.
            let h = AsyncHarness(sourceRate: 32_000, latency: 1_024, chunk: 512, signal: sine(440, rate: 32_000))
            h.drift = drift
            h.settle(seconds: 150)
            let settled = h.stats
            let out = h.run(seconds: 10)[0]
            let s = h.stats
            #expect(s.underruns == 0 && s.overflows == 0)
            #expect(abs(settled.correction - (drift - 1)) < 1e-4)
            #expect(abs(frequency(out, rate: 48_000) - 440 * drift) < 0.5)
        }
    }

    @Test func goesSilentOnUnderrunAndRecovers() {
        let h = AsyncHarness(sourceRate: 24_000, signal: { _, _ in 0.25 })
        h.settle(seconds: 0.5)
        #expect(h.stats.running)
        h.producing = false
        let gap = h.run(seconds: 0.2)[0]
        #expect(gap.suffix(1_000).allSatisfy { $0 == 0 })
        #expect(h.stats.underruns == 1)
        #expect(!h.stats.running)
        h.producing = true
        let back = h.run(seconds: 0.5)[0]
        #expect(h.stats.running)
        #expect(back.suffix(1_000).allSatisfy { abs($0 - 0.25) < 1e-3 })
    }

    @Test func keepsStereoChannelsApart() {
        let h = AsyncHarness(sourceRate: 32_000, channels: 2, signal: { _, c in c == 0 ? 0.1 : -0.3 })
        h.settle(seconds: 0.3)
        let out = h.run(seconds: 0.1)
        #expect(out[0].allSatisfy { abs($0 - 0.1) < 1e-4 })
        #expect(out[1].allSatisfy { abs($0 + 0.3) < 1e-4 })
        #expect(AudioCoreAsyncOutput(h.source, 2) == nil)
    }

    @Test func mixerPlaysAnAsyncTrackAlongsideClockedOnes() {
        var async = CoreHarness.mono(-1, 0)
        async.asyncSource = 0
        let mixer = CoreHarness(tracks: [CoreHarness.mono(0, 0), async])
        let device = AsyncHarness(sourceRate: 16_000, signal: { _, _ in 0.25 })
        var sources: [OpaquePointer?] = [device.source]
        AudioCoreSetAsyncSources(mixer.core, &sources, 1)
        // The mixer's IO cycles drive the async source; feed it in step.
        var out = mixer.cycle()
        for _ in 0..<400 {
            device.produceFor(frames: 64)
            out = mixer.cycle()
        }
        #expect(all(out.stream, left: 0.35, right: 0.35))
        var meters = AudioCoreMeters()
        AudioCoreReadMeters(mixer.core, &meters)
        #expect(abs(meters.peakLeft.1 - 0.25) < 1e-3)
    }
}

extension AsyncHarness {
    /// Advances the mixer clock without rendering, for tests where the mixer IOProc renders.
    func produceFor(frames: Int) {
        consumerTime += Double(frames) / targetRate
        produce()
    }
}
