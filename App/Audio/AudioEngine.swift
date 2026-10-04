import CoreAudio
import Foundation
import Observation
import os

/// Runs the mixer on a private aggregate device: the DJI receiver is the clock master and the
/// venue and stream outputs are drift-compensated sub-devices, so everything happens in one
/// small-buffer IOProc (the lowest-latency path CoreAudio offers).
@Observable @MainActor
final class AudioEngine {
    enum State: Equatable {
        case waitingForReceiver
        case running
        case failed(String)
    }

    private(set) var state: State = .waitingForReceiver
    private(set) var outputs: [AudioDeviceInfo] = []
    private(set) var inputChannels = 0
    private(set) var actualBufferFrames: UInt32 = 0
    /// Added latency of the venue path on top of the wireless link, in milliseconds.
    private(set) var venueLatencyMs: Double?
    private(set) var warning: String?

    var venueOutputUID: String? {
        didSet { UserDefaults.standard.set(venueOutputUID, forKey: "venueOutputUID"); scheduleRebuild(force: true) }
    }
    var streamOutputUID: String? {
        didSet { UserDefaults.standard.set(streamOutputUID, forKey: "streamOutputUID"); scheduleRebuild(force: true) }
    }
    var bufferFrames: UInt32 {
        didSet { UserDefaults.standard.set(Int(bufferFrames), forKey: "bufferFrames"); scheduleRebuild(force: true) }
    }

    @ObservationIgnored let core: OpaquePointer = AudioCoreCreate(1 << 20) // ~21 s of 6-channel audio for the recorder

    private let log = Logger(subsystem: "com.sauerdev.djicontroller", category: "engine")
    private let session = EngineSession()
    private var signature = ""
    private var rebuildTask: Task<Void, Never>?
    private var listener: AudioObjectPropertyListenerBlock?
    private var restartListener: AudioObjectPropertyListenerBlock?

    init() {
        venueOutputUID = UserDefaults.standard.string(forKey: "venueOutputUID")
        streamOutputUID = UserDefaults.standard.string(forKey: "streamOutputUID")
        let frames = UserDefaults.standard.integer(forKey: "bufferFrames")
        bufferFrames = frames > 0 ? UInt32(frames) : 64
    }

    func start() {
        installListeners()
        scheduleRebuild(force: true)
    }

    /// Device-list and audio-service-restart listeners. A restart of coreaudiod (e.g. after the
    /// stream device is installed) drops every listener and device, so both are re-created.
    private func installListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devices = CoreAudioHAL.address(kAudioHardwarePropertyDevices)
        var restarted = CoreAudioHAL.address(kAudioHardwarePropertyServiceRestarted)
        if let listener { AudioObjectRemovePropertyListenerBlock(system, &devices, DispatchQueue.main, listener) }
        if let restartListener { AudioObjectRemovePropertyListenerBlock(system, &restarted, DispatchQueue.main, restartListener) }

        let onDevices: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.scheduleRebuild(force: false) }
        }
        let onRestart: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.audioServiceRestarted() }
        }
        listener = onDevices
        restartListener = onRestart
        AudioObjectAddPropertyListenerBlock(system, &devices, DispatchQueue.main, onDevices)
        AudioObjectAddPropertyListenerBlock(system, &restarted, DispatchQueue.main, onRestart)
    }

    private func audioServiceRestarted() {
        log.info("audio service restarted; rebuilding")
        state = .waitingForReceiver
        session.queue.async { self.session.forget() }
        installListeners()
        signature = ""
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            self.scheduleRebuild(force: true)
        }
    }

    func readMeters() -> AudioCoreMeters {
        var meters = AudioCoreMeters()
        AudioCoreReadMeters(core, &meters)
        return meters
    }

    func setChannel(_ channel: Int, gainDB: Double, muted: Bool, venueSend: Bool) {
        AudioCoreSetChannelGain(core, Int32(channel), Self.linear(gainDB))
        AudioCoreSetChannelMute(core, Int32(channel), muted)
        AudioCoreSetChannelVenueSend(core, Int32(channel), venueSend)
    }

    func setStreamLevel(dB: Double) { AudioCoreSetStreamLevel(core, Self.linear(dB)) }
    func setVenueLevel(dB: Double) { AudioCoreSetVenueLevel(core, Self.linear(dB)) }

    /// Fader scale: the bottom of the travel (-60 dB) is silence.
    static func linear(_ dB: Double) -> Float { dB <= -60 ? 0 : Float(pow(10, dB / 20)) }

    // MARK: Rebuild

    private func scheduleRebuild(force: Bool) {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(force ? 50 : 600))
            guard !Task.isCancelled else { return }
            self.rebuildIfNeeded(force: force)
        }
    }

    private func rebuildIfNeeded(force: Bool) {
        let all = CoreAudioHAL.devices().filter { !$0.uid.hasPrefix(EngineSession.uidPrefix) }
        outputs = all.filter { $0.outputChannels > 0 && !$0.isDJIReceiver }
        let dji = all.first { $0.isDJIReceiver && $0.inputChannels > 0 }
        let venue = outputs.first { $0.uid == venueOutputUID }
        var stream = outputs.first { $0.uid == streamOutputUID }
        warning = nil
        if let s = stream, s.uid == venue?.uid {
            warning = "Stream and venue can't use the same output."
            stream = nil
        }

        let newSignature = [dji.map { "\($0.uid)|\($0.modelUID)|\($0.inputChannels)" } ?? "none",
                            venue?.uid ?? "-", stream?.uid ?? "-", String(bufferFrames)].joined(separator: "#")
        guard force || newSignature != signature else { return }
        signature = newSignature

        guard let dji else {
            session.queue.async { self.session.teardown() }
            state = .waitingForReceiver
            inputChannels = 0
            venueLatencyMs = nil
            return
        }
        let config = EngineSession.Config(dji: dji, venue: venue, stream: stream, bufferFrames: bufferFrames, core: core)
        session.queue.async {
            let result = self.session.build(config)
            Task { @MainActor in self.apply(result) }
        }
    }

    private func apply(_ result: Result<EngineSession.Info, EngineSession.Failure>) {
        switch result {
        case .success(let info):
            state = .running
            inputChannels = info.inputChannels
            actualBufferFrames = info.bufferFrames
            venueLatencyMs = info.venueLatencyMs
            log.info("engine running: \(info.inputChannels) in, buffer \(info.bufferFrames), venue \(info.venueLatencyMs ?? -1) ms")
        case .failure(let failure):
            state = .failed(failure.message)
            log.error("engine failed: \(failure.message, privacy: .public)")
        }
    }
}

/// CoreAudio objects owned by the engine; only touched on `queue`.
final class EngineSession: @unchecked Sendable {
    static let uidPrefix = "com.sauerdev.djicontroller.engine"

    struct Config: @unchecked Sendable {
        var dji: AudioDeviceInfo
        var venue: AudioDeviceInfo?
        var stream: AudioDeviceInfo?
        var bufferFrames: UInt32
        var core: OpaquePointer
    }

    struct Info {
        var inputChannels: Int
        var bufferFrames: UInt32
        var venueLatencyMs: Double?
    }

    struct Failure: Error {
        var message: String
    }

    let queue = DispatchQueue(label: "com.sauerdev.djicontroller.engine")
    private var aggregate: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?

    func build(_ config: Config) -> Result<Info, Failure> {
        teardown()
        var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: config.dji.uid]]
        for output in [config.venue, config.stream].compactMap({ $0 }) {
            subDevices.append([kAudioSubDeviceUIDKey: output.uid, kAudioSubDeviceDriftCompensationKey: 1])
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DJI Controller Engine",
            kAudioAggregateDeviceUIDKey: "\(Self.uidPrefix).\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: config.dji.uid,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
        ]
        var id = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != 0 else { return .failure(Failure(message: "Couldn't create the audio engine (\(status)).")) }
        aggregate = id

        // The aggregate's streams appear asynchronously.
        var inputLayout: [Int] = []
        for _ in 0..<50 {
            inputLayout = CoreAudioHAL.bufferLayout(id, kAudioObjectPropertyScopeInput)
            if !inputLayout.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let djiChannels = inputLayout.first, djiChannels > 0 else {
            teardown()
            return .failure(Failure(message: "The receiver's audio input didn't appear."))
        }
        CoreAudioHAL.setSampleRate(id, 48_000)
        CoreAudioHAL.setUInt32(id, kAudioDevicePropertyBufferFrameSize, config.bufferFrames)

        if let bad = CoreAudioHAL.unsupportedFormat(id, kAudioObjectPropertyScopeInput)
            ?? CoreAudioHAL.unsupportedFormat(id, kAudioObjectPropertyScopeOutput) {
            teardown()
            return .failure(Failure(message: "Unexpected audio format (\(bad))."))
        }

        let venueBuffers = config.venue.map { CoreAudioHAL.bufferLayout($0.id, kAudioObjectPropertyScopeOutput).count } ?? 0
        let outputLayout = CoreAudioHAL.bufferLayout(id, kAudioObjectPropertyScopeOutput)
        let venueIndex = config.venue != nil ? 0 : -1
        let streamIndex = config.stream != nil ? venueBuffers : -1
        guard streamIndex < outputLayout.count, venueIndex < outputLayout.count else {
            teardown()
            return .failure(Failure(message: "Output layout mismatch."))
        }
        AudioCoreSetLayout(config.core, 0, Int32(djiChannels), Int32(venueIndex), Int32(streamIndex))

        var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcID(id, AudioCoreIOProc, UnsafeMutableRawPointer(config.core), &proc) == noErr, let proc else {
            teardown()
            return .failure(Failure(message: "Couldn't attach the mixer."))
        }
        procID = proc
        let startStatus = AudioDeviceStart(id, proc)
        guard startStatus == noErr else {
            teardown()
            return .failure(Failure(message: "Couldn't start audio (\(startStatus))."))
        }

        let buffer = CoreAudioHAL.uint32(id, kAudioDevicePropertyBufferFrameSize)
        let venueMs = config.venue.map { venue -> Double in
            let frames = CoreAudioHAL.fixedLatencyFrames(config.dji.id, kAudioObjectPropertyScopeInput)
                + CoreAudioHAL.fixedLatencyFrames(venue.id, kAudioObjectPropertyScopeOutput) + 2 * buffer
            return Double(frames) / 48.0
        }
        return .success(Info(inputChannels: djiChannels, bufferFrames: buffer, venueLatencyMs: venueMs))
    }

    /// After an audio service restart the old objects no longer exist; drop them without calls.
    func forget() {
        procID = nil
        aggregate = 0
    }

    func teardown() {
        if aggregate != 0, let procID {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
        }
        procID = nil
        if aggregate != 0 {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = 0
        }
    }
}
