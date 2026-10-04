import CoreAudio
import Foundation
import Observation
import os

/// Runs the mixer on a private aggregate device. Every input device a track uses joins it: the
/// DJI receiver is the clock master when a track uses it (otherwise the first input device is),
/// and all other devices are drift-compensated, so mixing, metering and recording happen in one
/// small-buffer IOProc with every track sample-aligned.
@Observable @MainActor
final class AudioEngine {
    enum State: Equatable {
        /// No tracks yet.
        case idle
        /// Tracks exist but none of their sources is connected.
        case waitingForInputs
        case running
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var outputs: [AudioDeviceInfo] = []
    /// Input devices tracks can use, other than the DJI receiver (whose channels are offered as TX1-TX4).
    private(set) var inputs: [AudioDeviceInfo] = []
    private(set) var receiverDevice: AudioDeviceInfo?
    /// Whether each track's source is connected, in track order.
    private(set) var trackAvailable: [Bool] = []
    private(set) var actualBufferFrames: UInt32 = 0
    /// Added latency of the venue path on top of the wireless link, in milliseconds.
    private(set) var venueLatencyMs: Double?
    private(set) var warning: String?

    /// Set by the app model whenever tracks are added, removed or re-sourced.
    var trackSources: [TrackSource] = [] {
        didSet { if trackSources != oldValue { scheduleRebuild(force: true) } }
    }
    var venueOutputUID: String? {
        didSet { UserDefaults.standard.set(venueOutputUID, forKey: "venueOutputUID"); scheduleRebuild(force: true) }
    }
    var streamOutputUID: String? {
        didSet { UserDefaults.standard.set(streamOutputUID, forKey: "streamOutputUID"); scheduleRebuild(force: true) }
    }
    var bufferFrames: UInt32 {
        didSet { UserDefaults.standard.set(Int(bufferFrames), forKey: "bufferFrames"); scheduleRebuild(force: true) }
    }

    @ObservationIgnored let core: OpaquePointer = AudioCoreCreate(1 << 19) // ~11 s of 18-channel audio for the recorder

    private let log = Logger(subsystem: "com.sauerdev.lavboard", category: "engine")
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
        state = trackSources.isEmpty ? .idle : .waitingForInputs
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

    func setTrack(_ index: Int, gainDB: Double, muted: Bool, venueSend: Bool, balance: Double) {
        AudioCoreSetTrackGain(core, Int32(index), Self.linear(gainDB))
        AudioCoreSetTrackMute(core, Int32(index), muted)
        AudioCoreSetTrackVenueSend(core, Int32(index), venueSend)
        AudioCoreSetTrackBalance(core, Int32(index), Float(balance))
    }

    func setStreamLevel(dB: Double) { AudioCoreSetStreamLevel(core, Self.linear(dB)) }
    func setVenueLevel(dB: Double) { AudioCoreSetVenueLevel(core, Self.linear(dB)) }

    /// Fader scale: the bottom of the travel (-60 dB) is silence.
    static func linear(_ dB: Double) -> Float { dB <= -60 ? 0 : Float(pow(10, dB / 20)) }

    /// The input device behind a track, if it is connected.
    func device(for source: TrackSource) -> AudioDeviceInfo? {
        switch source {
        case .transmitter: receiverDevice
        case .device(let uid, _, _, _): inputs.first { $0.uid == uid }
        }
    }

    // MARK: Rebuild

    private func scheduleRebuild(force: Bool) {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(force ? 50 : 600))
            guard !Task.isCancelled else { return }
            self.rebuildIfNeeded(force: force)
        }
    }

    /// A track source resolved to a connected device that can join the engine.
    private struct Resolved: Equatable {
        var device: AudioDeviceInfo
        var channel: Int
        var stereo: Bool
    }

    private func resolve(_ source: TrackSource) -> Resolved? {
        switch source {
        case .transmitter(let slot):
            guard let receiverDevice, slot < receiverDevice.inputChannels else { return nil }
            return Resolved(device: receiverDevice, channel: slot, stereo: false)
        case .device(let uid, _, let channel, let stereo):
            guard let device = inputs.first(where: { $0.uid == uid }), device.canJoinEngine,
                  channel + (stereo ? 1 : 0) < device.inputChannels else { return nil }
            return Resolved(device: device, channel: channel, stereo: stereo)
        }
    }

    private func rebuildIfNeeded(force: Bool) {
        let all = CoreAudioHAL.devices().filter { !$0.uid.hasPrefix(EngineSession.uidPrefix) }
        outputs = all.filter { $0.outputChannels > 0 && !$0.isDJIReceiver }
        inputs = all.filter { $0.inputChannels > 0 && !$0.isDJIReceiver && $0.uid != StreamDevice.deviceUID }
        receiverDevice = all.first { $0.isDJIReceiver && $0.inputChannels > 0 }
        let venue = outputs.first { $0.uid == venueOutputUID }
        var stream = outputs.first { $0.uid == streamOutputUID }
        warning = nil
        if let s = stream, s.uid == venue?.uid {
            warning = "Stream and venue can't use the same output."
            stream = nil
        }

        let resolved = trackSources.map(resolve)
        trackAvailable = resolved.map { $0 != nil }
        let newSignature = (resolved.map { r in r.map { "\($0.device.uid)|\($0.device.inputChannels)|\($0.channel)|\($0.stereo)" } ?? "-" }
            + [venue?.uid ?? "-", stream?.uid ?? "-", String(bufferFrames)]).joined(separator: "#")
        guard force || newSignature != signature else { return }
        signature = newSignature

        // Clock master first: the receiver when a track uses it, otherwise the first used device.
        var devices: [AudioDeviceInfo] = []
        for r in resolved.compactMap({ $0 }) where !devices.contains(where: { $0.uid == r.device.uid }) {
            if r.device.isDJIReceiver { devices.insert(r.device, at: 0) } else { devices.append(r.device) }
        }
        guard !devices.isEmpty else {
            session.queue.async { self.session.teardown() }
            state = trackSources.isEmpty ? .idle : .waitingForInputs
            venueLatencyMs = nil
            return
        }

        let config = EngineSession.Config(
            inputs: devices,
            tracks: resolved.map { $0.map { (uid: $0.device.uid, channel: $0.channel, stereo: $0.stereo) } },
            venue: venue, stream: stream, bufferFrames: bufferFrames, core: core)
        session.queue.async {
            let result = self.session.build(config)
            Task { @MainActor in self.apply(result) }
        }
    }

    private func apply(_ result: Result<EngineSession.Info, EngineSession.Failure>) {
        switch result {
        case .success(let info):
            state = .running
            actualBufferFrames = info.bufferFrames
            venueLatencyMs = info.venueLatencyMs
            log.info("engine running: \(info.inputDevices) input devices, buffer \(info.bufferFrames), venue \(info.venueLatencyMs ?? -1) ms")
        case .failure(let failure):
            state = .failed(failure.message)
            log.error("engine failed: \(failure.message, privacy: .public)")
        }
    }
}

/// CoreAudio objects owned by the engine; only touched on `queue`.
final class EngineSession: @unchecked Sendable {
    static let uidPrefix = "com.sauerdev.lavboard.engine"

    struct Config: @unchecked Sendable {
        /// Input devices in sub-device order; the first is the clock master.
        var inputs: [AudioDeviceInfo]
        /// One entry per track; nil when the source isn't connected.
        var tracks: [(uid: String, channel: Int, stereo: Bool)?]
        var venue: AudioDeviceInfo?
        var stream: AudioDeviceInfo?
        var bufferFrames: UInt32
        var core: OpaquePointer
    }

    struct Info {
        var inputDevices: Int
        var bufferFrames: UInt32
        var venueLatencyMs: Double?
    }

    struct Failure: Error {
        var message: String
    }

    let queue = DispatchQueue(label: "com.sauerdev.lavboard.engine")
    private var aggregate: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?

    func build(_ config: Config) -> Result<Info, Failure> {
        teardown()
        guard let master = config.inputs.first else { return .failure(Failure(message: "No inputs to mix.")) }

        // Each device appears once even if it is both an input and an output (e.g. an interface).
        var members: [AudioDeviceInfo] = []
        for device in config.inputs + [config.venue, config.stream].compactMap({ $0 })
        where !members.contains(where: { $0.uid == device.uid }) {
            members.append(device)
        }
        let subDevices: [[String: Any]] = members.map { device in
            device.uid == master.uid
                ? [kAudioSubDeviceUIDKey: device.uid]
                : [kAudioSubDeviceUIDKey: device.uid, kAudioSubDeviceDriftCompensationKey: 1]
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lavboard Engine",
            kAudioAggregateDeviceUIDKey: "\(Self.uidPrefix).\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: master.uid,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
        ]
        var id = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != 0 else { return .failure(Failure(message: "Couldn't create the audio engine (\(status)).")) }
        aggregate = id

        // The aggregate's streams appear asynchronously.
        let expectedInputs = members.reduce(0) { $0 + CoreAudioHAL.bufferLayout($1.id, kAudioObjectPropertyScopeInput).count }
        var inputLayout: [Int] = []
        for _ in 0..<50 {
            inputLayout = CoreAudioHAL.bufferLayout(id, kAudioObjectPropertyScopeInput)
            if inputLayout.count >= expectedInputs { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard inputLayout.count == expectedInputs else {
            teardown()
            return .failure(Failure(message: "An input device didn't join the engine."))
        }
        CoreAudioHAL.setSampleRate(id, 48_000)
        CoreAudioHAL.setUInt32(id, kAudioDevicePropertyBufferFrameSize, config.bufferFrames)

        if let bad = CoreAudioHAL.unsupportedFormat(id, kAudioObjectPropertyScopeInput)
            ?? CoreAudioHAL.unsupportedFormat(id, kAudioObjectPropertyScopeOutput) {
            teardown()
            return .failure(Failure(message: "Unexpected audio format (\(bad))."))
        }

        let map = members.map { device in
            BufferMap.SubDevice(uid: device.uid,
                                inputStreams: CoreAudioHAL.bufferLayout(device.id, kAudioObjectPropertyScopeInput),
                                outputStreams: CoreAudioHAL.bufferLayout(device.id, kAudioObjectPropertyScopeOutput))
        }
        let layouts: [AudioCoreTrackLayout] = config.tracks.map { track in
            guard let track, let left = BufferMap.input(channel: track.channel, of: track.uid, in: map) else {
                return AudioCoreTrackLayout(buffer: -1, channel: -1, bufferRight: -1, channelRight: -1, stereo: track?.stereo ?? false)
            }
            let right = track.stereo ? BufferMap.input(channel: track.channel + 1, of: track.uid, in: map) : nil
            return AudioCoreTrackLayout(buffer: Int32(left.buffer), channel: Int32(left.channel),
                                        bufferRight: Int32(right?.buffer ?? -1), channelRight: Int32(right?.channel ?? -1),
                                        stereo: track.stereo)
        }
        let venueIndex = config.venue.flatMap { BufferMap.firstOutput(of: $0.uid, in: map) } ?? -1
        let streamIndex = config.stream.flatMap { BufferMap.firstOutput(of: $0.uid, in: map) } ?? -1
        layouts.withUnsafeBufferPointer {
            AudioCoreSetLayout(config.core, $0.baseAddress, Int32(layouts.count), Int32(venueIndex), Int32(streamIndex))
        }

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
            let frames = CoreAudioHAL.fixedLatencyFrames(master.id, kAudioObjectPropertyScopeInput)
                + CoreAudioHAL.fixedLatencyFrames(venue.id, kAudioObjectPropertyScopeOutput) + 2 * buffer
            return Double(frames) / 48.0
        }
        return .success(Info(inputDevices: config.inputs.count, bufferFrames: buffer, venueLatencyMs: venueMs))
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
