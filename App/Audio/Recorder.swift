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

    private let log = Logger(subsystem: "com.sauerdev.lavboard", category: "recorder")
    private var writer: TrackWriter?

    init() {
        let saved = UserDefaults.standard.string(forKey: "recordingFolder")
        folder = saved.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Lavboard")
        format = Format(rawValue: UserDefaults.standard.string(forKey: "recordingFormat") ?? "") ?? .pcm24
    }

    /// One file per track (mono or stereo, matching the track) plus the stereo mix.
    func start(core: OpaquePointer, tracks: [(name: String, channels: Int)]) {
        guard !isRecording else { return }
        error = nil
        guard AudioCoreRingChannels(core) == tracks.reduce(2, { $0 + $1.channels }) else {
            error = "Couldn't start recording: the tracks are still being set up. Try again in a moment."
            return
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let session = folder.appendingPathComponent("Session \(stamp.string(from: Date()))")
        do {
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            let files = tracks.enumerated().map { i, track in
                (name: String(format: "%02d %@.wav", i + 1, Self.sanitize(track.name.isEmpty ? "Track \(i + 1)" : track.name)),
                 channels: track.channels)
            } + [(name: String(format: "%02d Mix.wav", tracks.count + 1), channels: 2)]
            writer = try TrackWriter(core: core, folder: session, files: files, format: format)
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
    /// Channel count of each file, in ring-buffer column order.
    private var fileChannels: [Int] = []
    private var thread: Thread?
    private let stopLock = NSCondition()
    private var stopRequested = false
    private var finished = false

    init(core: OpaquePointer, folder: URL, files specs: [(name: String, channels: Int)], format: Recorder.Format) throws {
        self.core = core
        for spec in specs {
            files.append(try Self.makeFile(url: folder.appendingPathComponent(spec.name), channels: UInt32(spec.channels), format: format))
            fileChannels.append(spec.channels)
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
        let ringChannels = Int(AudioCoreRingChannels(core))
        var interleaved = [Float](repeating: 0, count: Int(chunk) * ringChannels)
        var scratch = [Float](repeating: 0, count: Int(chunk) * 2)
        while true {
            stopLock.lock()
            let stopping = stopRequested
            stopLock.unlock()
            var frames: UInt32
            repeat {
                frames = interleaved.withUnsafeMutableBufferPointer { AudioCoreReadRecorded(core, $0.baseAddress!, chunk) }
                guard frames > 0 else { break }
                let n = Int(frames)
                var column = 0
                for (file, channels) in zip(files, fileChannels) {
                    for f in 0..<n {
                        for c in 0..<channels { scratch[f * channels + c] = interleaved[f * ringChannels + column + c] }
                    }
                    write(file: file, samples: &scratch, frames: frames, channels: UInt32(channels))
                    column += channels
                }
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
