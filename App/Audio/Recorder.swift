import AudioToolbox
import Foundation
import Observation
import os

/// Writes the engine's ring buffer to one mono WAV per transmitter (raw, pre-fader, so
/// live mutes never destroy material) plus a stereo program mix.
@Observable @MainActor
final class Recorder {
    enum Format: String, CaseIterable, Identifiable {
        case pcm24 = "24-bit"
        case float32 = "32-bit float"
        var id: String { rawValue }
    }

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    private(set) var lastFolder: URL?
    private(set) var droppedBuffers: UInt64 = 0
    private(set) var error: String?

    var folder: URL {
        didSet { UserDefaults.standard.set(folder.path, forKey: "recordingFolder") }
    }
    var format: Format {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "recordingFormat") }
    }

    private let log = Logger(subsystem: "com.sauerdev.djicontroller", category: "recorder")
    private var writer: TrackWriter?

    init() {
        let saved = UserDefaults.standard.string(forKey: "recordingFolder")
        folder = saved.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("DJI Recordings")
        format = Format(rawValue: UserDefaults.standard.string(forKey: "recordingFormat") ?? "") ?? .pcm24
    }

    func start(core: OpaquePointer, trackNames: [String]) {
        guard !isRecording else { return }
        error = nil
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let session = folder.appendingPathComponent("Session \(stamp.string(from: Date()))")
        do {
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            let names = trackNames.enumerated().map { i, name in
                String(format: "%02d %@.wav", i + 1, Self.sanitize(name.isEmpty ? "Mic \(i + 1)" : name))
            } + ["05 Mix.wav"]
            writer = try TrackWriter(core: core, folder: session, names: names, format: format)
            writer?.start()
            lastFolder = session
            startedAt = Date()
            isRecording = true
            log.info("recording to \(session.path, privacy: .public)")
        } catch {
            self.error = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRecording, let writer else { return }
        droppedBuffers = writer.stop()
        self.writer = nil
        isRecording = false
        startedAt = nil
        if droppedBuffers > 0 { error = "Recording dropped \(droppedBuffers) buffers (disk too slow)." }
    }

    private static func sanitize(_ name: String) -> String {
        String(name.map { "/:\\".contains($0) ? "-" : $0 })
    }
}

/// Background writer: drains the lock-free ring buffer every 20 ms.
private final class TrackWriter: @unchecked Sendable {
    private let core: OpaquePointer
    private var files: [ExtAudioFileRef] = []
    private var thread: Thread?
    private let stopLock = NSCondition()
    private var stopRequested = false
    private var finished = false

    init(core: OpaquePointer, folder: URL, names: [String], format: Recorder.Format) throws {
        self.core = core
        for (i, name) in names.enumerated() {
            let channels: UInt32 = i == AC_MAX_INPUTS ? 2 : 1
            files.append(try Self.makeFile(url: folder.appendingPathComponent(name), channels: channels, format: format))
        }
    }

    func start() {
        AudioCoreStartRecording(core)
        let thread = Thread { [self] in run() }
        thread.qualityOfService = .userInitiated
        thread.name = "TrackWriter"
        self.thread = thread
        thread.start()
    }

    /// Stops capture, flushes what is buffered, closes the files and returns dropped buffer count.
    func stop() -> UInt64 {
        AudioCoreStopRecording(core)
        stopLock.lock()
        stopRequested = true
        while !finished { stopLock.wait() }
        stopLock.unlock()
        var meters = AudioCoreMeters()
        AudioCoreReadMeters(core, &meters)
        return meters.overruns
    }

    private func run() {
        let chunk: UInt32 = 4096
        let ringChannels = Int(AC_RING_CHANNELS)
        var interleaved = [Float](repeating: 0, count: Int(chunk) * ringChannels)
        var mono = [Float](repeating: 0, count: Int(chunk))
        var stereo = [Float](repeating: 0, count: Int(chunk) * 2)
        while true {
            stopLock.lock()
            let stopping = stopRequested
            stopLock.unlock()
            var frames: UInt32
            repeat {
                frames = interleaved.withUnsafeMutableBufferPointer { AudioCoreReadRecorded(core, $0.baseAddress!, chunk) }
                guard frames > 0 else { break }
                let n = Int(frames)
                for track in 0..<Int(AC_MAX_INPUTS) {
                    for f in 0..<n { mono[f] = interleaved[f * ringChannels + track] }
                    write(file: files[track], samples: &mono, frames: frames, channels: 1)
                }
                for f in 0..<n {
                    stereo[f * 2] = interleaved[f * ringChannels + 4]
                    stereo[f * 2 + 1] = interleaved[f * ringChannels + 5]
                }
                write(file: files[Int(AC_MAX_INPUTS)], samples: &stereo, frames: frames, channels: 2)
            } while frames == chunk
            if stopping { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        files.forEach { ExtAudioFileDispose($0) }
        stopLock.lock()
        finished = true
        stopLock.signal()
        stopLock.unlock()
    }

    private func write(file: ExtAudioFileRef, samples: inout [Float], frames: UInt32, channels: UInt32) {
        samples.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: channels, mDataByteSize: frames * channels * 4, mData: raw.baseAddress))
            ExtAudioFileWrite(file, frames, &list)
        }
    }

    private static func makeFile(url: URL, channels: UInt32, format: Recorder.Format) throws -> ExtAudioFileRef {
        let bits: UInt32 = format == .pcm24 ? 24 : 32
        let flags: AudioFormatFlags = format == .pcm24
            ? kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            : kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: bits / 8 * channels, mFramesPerPacket: 1, mBytesPerFrame: bits / 8 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
        var file: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &fileFormat, nil,
                                               AudioFileFlags.eraseFile.rawValue, &file)
        guard status == noErr, let file else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)
        guard status == noErr else {
            ExtAudioFileDispose(file)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return file
    }
}
