import CoreAudio
import Foundation
import Observation
import os

/// Runs the mixer on a private aggregate device. Every 48 kHz input device a track uses joins it:
/// the DJI receiver is the clock master when a track uses it (otherwise the first input device
/// is), and all other devices are drift-compensated, so mixing, metering and recording happen in
/// one small-buffer IOProc with every track sample-aligned.
///
/// Devices that can't join (Bluetooth mics, devices without 48 kHz) run on their own clock: each
/// gets its own IOProc feeding an async source that the mixer resamples, with a little latency.
/// With no 48 kHz input in use, an output device clocks the mixer.
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
    /// How far behind the 48 kHz inputs each own-clock track runs, in milliseconds; nil for tracks
    /// on the engine's clock.
    private(set) var trackLatencyMs: [Double?] = []
    private(set) var actualBufferFrames: UInt32 = 0
    /// Added latency of the venue path on top of the wireless link, in milliseconds.
    private(set) var venueLatencyMs: Double?
    /// A routing problem to show the user, if any.
    var warning: String? { routingWarning ?? buildWarning }
    private var routingWarning: String?
    /// A device that didn't start with the running engine.
    private var buildWarning: String?
    /// True from the moment tracks, outputs or devices change until the engine runs with the
    /// resulting layout, so a recording can't start against the old one.
    private(set) var layoutPending = false

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
    /// Each build gets a number; only the latest one's result is applied.
    private var buildGeneration = 0
    private var appliedGeneration = 0
    private var rebuildTask: Task<Void, Never>?
    private var listener: AudioObjectPropertyListenerBlock?
    private var restartListener: AudioObjectPropertyListenerBlock?
    /// Sample-rate listeners on own-clock devices in use (a Bluetooth headset changes rate when
    /// its mic is in use elsewhere).
    private var rateListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    /// Own-clock USB devices already moved to their preferred rate; each is only asked once, so a
    /// rate the user picks later in Audio MIDI Setup sticks.
    private var rateRequested: Set<String> = []
    @ObservationIgnored private var lastOwnClockStats: [(name: String, rate: Double, stats: AudioCoreAsyncStats)] = []

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
        layoutPending = true
        buildGeneration += 1 // results of a build already in flight refer to dead objects
        rateListeners = [:] // the restart dropped them along with the devices
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

    private func scheduleRebuild(force: Bool, after delay: Duration? = nil) {
        layoutPending = true
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            try? await Task.sleep(for: delay ?? .milliseconds(force ? 50 : 600))
            guard !Task.isCancelled else { return }
            self.rebuildIfNeeded(force: force)
        }
    }

    /// A track source resolved to a connected device.
    private struct Resolved: Equatable {
        var device: AudioDeviceInfo
        var channel: Int
        var stereo: Bool
        var ownClock: Bool { device.runsOnOwnClock }
    }

    private func resolve(_ source: TrackSource) -> Resolved? {
        switch source {
        case .transmitter(let slot):
            guard let receiverDevice, slot < receiverDevice.inputChannels else { return nil }
            return Resolved(device: receiverDevice, channel: slot, stereo: false)
        case .device(let uid, _, let channel, let stereo):
            guard let device = inputs.first(where: { $0.uid == uid }),
                  channel >= 0, channel + (stereo ? 1 : 0) < device.usableInputChannels else { return nil }
            return Resolved(device: device, channel: channel, stereo: stereo)
        }
    }

    /// Moves own-clock USB devices to their best rate up to 48 kHz (the C922 webcam starts at
    /// 16 kHz). Returns true if a rate changed, so the build waits for the device to settle.
    private func preferRates(_ resolved: [Resolved]) -> Bool {
        var changed = false
        for r in resolved where r.ownClock && !r.device.isBluetooth && !rateRequested.contains(r.device.uid) {
            rateRequested.insert(r.device.uid)
            if let best = CoreAudioHAL.preferredRate(among: CoreAudioHAL.availableRates(r.device.id)), best != r.device.nominalRate,
               CoreAudioHAL.setSampleRate(r.device.id, best) == noErr {
                log.info("\(r.device.name, privacy: .public): \(r.device.nominalRate) -> \(best) Hz")
                changed = true
            }
        }
        return changed
    }

    private func watchRates(of devices: [AudioDeviceInfo]) {
        var addr = CoreAudioHAL.address(kAudioDevicePropertyNominalSampleRate)
        let ids = Set(devices.map(\.id))
        for (id, block) in rateListeners where !ids.contains(id) {
            AudioObjectRemovePropertyListenerBlock(id, &addr, DispatchQueue.main, block)
            rateListeners[id] = nil
        }
        for id in ids where rateListeners[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.scheduleRebuild(force: false) }
            }
            if AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block) == noErr { rateListeners[id] = block }
        }
    }

    /// The device that clocks the mixer when no track uses a 48 kHz input: a selected output, else
    /// the built-in output (a hardware clock), else the Lavboard stream device, else any output
    /// that can join.
    private func clockDevice(venue: AudioDeviceInfo?, stream: AudioDeviceInfo?) -> AudioDeviceInfo? {
        [stream, venue].compactMap { $0 }.first(where: \.canJoinEngine)
            ?? outputs.first { $0.transportType == kAudioDeviceTransportTypeBuiltIn && $0.canJoinEngine }
            ?? outputs.first { $0.uid == StreamDevice.deviceUID }
            ?? outputs.first(where: \.canJoinEngine)
    }

    private func rebuildIfNeeded(force: Bool) {
        let all = CoreAudioHAL.devices()
        outputs = all.filter { $0.outputChannels > 0 && !$0.isDJIReceiver }
        inputs = all.filter { $0.inputChannels > 0 && !$0.isDJIReceiver && $0.uid != StreamDevice.deviceUID }
        receiverDevice = all.first { $0.isDJIReceiver && $0.inputChannels > 0 }
        let venue = outputs.first { $0.uid == venueOutputUID }
        var stream = outputs.first { $0.uid == streamOutputUID }
        routingWarning = nil
        if let s = stream, s.uid == venue?.uid {
            routingWarning = "Stream and venue can't use the same output."
            stream = nil
        }

        let resolved = trackSources.map(resolve)
        trackAvailable = resolved.map { $0 != nil }
        if preferRates(resolved.compactMap { $0 }) {
            scheduleRebuild(force: true, after: .milliseconds(300))
            return
        }
        let ownClock = Self.unique(resolved.compactMap { $0 }.filter(\.ownClock).map(\.device))
        watchRates(of: ownClock)
        let clock = clockDevice(venue: venue, stream: stream)
        let newSignature = (resolved.map { r in
            r.map { "\($0.device.uid)|\($0.device.inputChannels)|\($0.channel)|\($0.stereo)|\($0.ownClock ? $0.device.nominalRate : 0)" } ?? "-"
        } + [venue?.uid ?? "-", stream?.uid ?? "-", clock?.uid ?? "-", String(bufferFrames)]).joined(separator: "#")
        guard force || newSignature != signature else {
            if appliedGeneration == buildGeneration { layoutPending = false }
            return
        }
        signature = newSignature
        buildGeneration += 1
        let generation = buildGeneration

        // Clock master first: the receiver when a track uses it, otherwise the first used device.
        var devices: [AudioDeviceInfo] = []
        for r in resolved.compactMap({ $0 }) where !r.ownClock && !devices.contains(where: { $0.uid == r.device.uid }) {
            if r.device.isDJIReceiver { devices.insert(r.device, at: 0) } else { devices.append(r.device) }
        }
        guard !devices.isEmpty || !ownClock.isEmpty else {
            session.queue.async { self.session.teardown() }
            state = trackSources.isEmpty ? .idle : .waitingForInputs
            venueLatencyMs = nil
            buildWarning = nil
            trackLatencyMs = trackSources.map { _ in nil }
            appliedGeneration = generation
            layoutPending = false
            return
        }

        let config = EngineSession.Config(
            inputs: devices,
            ownClock: ownClock,
            clock: devices.isEmpty ? clock : nil,
            tracks: resolved.map { $0.map { (uid: $0.device.uid, channel: $0.channel, stereo: $0.stereo, ownClock: $0.ownClock) } },
            venue: venue, stream: stream, bufferFrames: bufferFrames, core: core)
        session.queue.async {
            let result = self.session.build(config)
            Task { @MainActor in self.apply(result, generation: generation) }
        }
    }

    private func apply(_ result: Result<EngineSession.Info, EngineSession.Failure>, generation: Int) {
        // A newer build is queued behind this one and will replace it.
        guard generation == buildGeneration else { return }
        appliedGeneration = generation
        layoutPending = false
        switch result {
        case .success(let info):
            state = .running
            actualBufferFrames = info.bufferFrames
            venueLatencyMs = info.venueLatencyMs
            trackLatencyMs = info.trackLatencyMs
            buildWarning = info.problems.first
            log.info("engine running: \(info.inputDevices) input devices, buffer \(info.bufferFrames), venue \(info.venueLatencyMs ?? -1) ms")
        case .failure(let failure):
            state = .failed(failure.message)
            buildWarning = nil
            trackLatencyMs = trackSources.map { _ in nil }
            log.error("engine failed: \(failure.message, privacy: .public)")
        }
    }

    private static func unique(_ devices: [AudioDeviceInfo]) -> [AudioDeviceInfo] {
        var seen = Set<String>()
        return devices.filter { seen.insert($0.uid).inserted }
    }

    /// Resampler state of each own-clock device, for diagnostics: the last reading, refreshed in
    /// the background so a slow engine build never blocks the caller.
    func ownClockStats() -> [(name: String, rate: Double, stats: AudioCoreAsyncStats)] {
        session.queue.async {
            let stats = self.session.ownClockStats()
            Task { @MainActor in self.lastOwnClockStats = stats }
        }
        return lastOwnClockStats
    }
}

/// CoreAudio objects owned by the engine; only touched on `queue`.
final class EngineSession: @unchecked Sendable {
    static let uidPrefix = "com.sauerdev.lavboard.engine"

    struct Config: @unchecked Sendable {
        /// 48 kHz input devices in sub-device order; the first is the clock master.
        var inputs: [AudioDeviceInfo]
        /// Input devices captured on their own clock and resampled.
        var ownClock: [AudioDeviceInfo]
        /// Clocks the mixer when `inputs` is empty.
        var clock: AudioDeviceInfo?
        /// One entry per track; nil when the source isn't connected.
        var tracks: [(uid: String, channel: Int, stereo: Bool, ownClock: Bool)?]
        var venue: AudioDeviceInfo?
        var stream: AudioDeviceInfo?
        var bufferFrames: UInt32
        var core: OpaquePointer
    }

    struct Info {
        var inputDevices: Int
        var bufferFrames: UInt32
        var venueLatencyMs: Double?
        /// Per track: how far an own-clock track runs behind the 48 kHz inputs; nil otherwise.
        var trackLatencyMs: [Double?]
        /// Devices that didn't start and stay silent, worded for the user.
        var problems: [String]
    }

    struct Failure: Error {
        var message: String
    }

    /// A device on its own clock: its IOProc fills `source`, which the mixer resamples.
    private struct OwnClock {
        var device: AudioDeviceInfo
        var proc: AudioDeviceIOProcID
        var source: OpaquePointer
        var rate: Double
        var latencyMs: Double
    }

    let queue = DispatchQueue(label: "com.sauerdev.lavboard.engine")
    private var aggregate: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private var ownClock: [OwnClock] = []
    private var core: OpaquePointer?

    func build(_ config: Config) -> Result<Info, Failure> {
        teardown()
        core = config.core
        guard let master = config.inputs.first ?? config.clock else {
            return .failure(Failure(message: "No output device to run the mixer on."))
        }

        // Each device appears once even if it is both an input and an output (e.g. an interface).
        var members: [AudioDeviceInfo] = []
        for device in config.inputs + [config.venue, config.stream, master].compactMap({ $0 })
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
        let map = members.map { device in
            BufferMap.SubDevice(uid: device.uid,
                                inputStreams: CoreAudioHAL.bufferLayout(device.id, kAudioObjectPropertyScopeInput),
                                outputStreams: CoreAudioHAL.bufferLayout(device.id, kAudioObjectPropertyScopeOutput))
        }
        let expectedInputs = map.reduce(0) { $0 + $1.inputStreams.count }
        let expectedOutputs = map.reduce(0) { $0 + $1.outputStreams.count }
        var inputLayout: [Int] = []
        var outputLayout: [Int] = []
        for _ in 0..<50 {
            inputLayout = CoreAudioHAL.bufferLayout(id, kAudioObjectPropertyScopeInput)
            outputLayout = CoreAudioHAL.bufferLayout(id, kAudioObjectPropertyScopeOutput)
            if inputLayout.count >= expectedInputs && outputLayout.count >= expectedOutputs { break }
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

        // Own-clock devices start capturing first, so audio is buffered by the time the mixer runs.
        var problems: [String] = []
        let clockedInputMs = config.inputs.isEmpty ? 0
            : Double(CoreAudioHAL.fixedLatencyFrames(master.id, kAudioObjectPropertyScopeInput) + config.bufferFrames) / 48.0
        var sourceIndex: [String: Int] = [:]
        var sources: [OpaquePointer?] = []
        for device in config.ownClock {
            sourceIndex[device.uid] = sources.count
            if let started = startOwnClock(device, mixerBuffer: config.bufferFrames) {
                ownClock.append(started)
                sources.append(started.source)
            } else {
                sources.append(nil)
                problems.append("\(device.name) couldn't start, so its track is silent.")
            }
        }

        let silent = { (stereo: Bool) in
            AudioCoreTrackLayout(buffer: -1, channel: -1, bufferRight: -1, channelRight: -1, stereo: stereo, asyncSource: -1)
        }
        let layouts: [AudioCoreTrackLayout] = config.tracks.map { track in
            guard let track else { return silent(false) }
            if track.ownClock {
                guard let index = sourceIndex[track.uid] else { return silent(track.stereo) }
                return AudioCoreTrackLayout(buffer: -1, channel: Int32(track.channel), bufferRight: -1,
                                            channelRight: Int32(track.stereo ? track.channel + 1 : -1),
                                            stereo: track.stereo, asyncSource: Int32(index))
            }
            guard let left = BufferMap.input(channel: track.channel, of: track.uid, in: map) else { return silent(track.stereo) }
            let right = track.stereo ? BufferMap.input(channel: track.channel + 1, of: track.uid, in: map) : nil
            return AudioCoreTrackLayout(buffer: Int32(left.buffer), channel: Int32(left.channel),
                                        bufferRight: Int32(right?.buffer ?? -1), channelRight: Int32(right?.channel ?? -1),
                                        stereo: track.stereo, asyncSource: -1)
        }
        // An output index is only used if the aggregate really has that stream, with the
        // device's channel count; otherwise the output stays silent and the user is told.
        func outputIndex(_ device: AudioDeviceInfo?) -> Int {
            guard let device else { return -1 }
            guard let index = BufferMap.firstOutput(of: device.uid, in: map),
                  let expected = map.first(where: { $0.uid == device.uid })?.outputStreams.first,
                  index < outputLayout.count, outputLayout[index] == expected
            else {
                problems.append("\(device.name) didn't join the engine, so it is silent.")
                return -1
            }
            return index
        }
        let venueIndex = outputIndex(config.venue)
        let streamIndex = outputIndex(config.stream)
        layouts.withUnsafeBufferPointer {
            AudioCoreSetLayout(config.core, $0.baseAddress, Int32(layouts.count), Int32(venueIndex), Int32(streamIndex))
        }
        sources.withUnsafeBufferPointer {
            AudioCoreSetAsyncSources(config.core, $0.baseAddress, Int32(sources.count))
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
        let trackLatency: [Double?] = config.tracks.map { track in
            guard let track, track.ownClock, let own = ownClock.first(where: { $0.device.uid == track.uid }) else { return nil }
            return max(0, own.latencyMs - clockedInputMs)
        }
        return .success(Info(inputDevices: config.inputs.count + ownClock.count, bufferFrames: buffer,
                             venueLatencyMs: venueIndex >= 0 ? venueMs : nil, trackLatencyMs: trackLatency, problems: problems))
    }

    /// Starts capturing a device on its own clock at its current rate.
    private func startOwnClock(_ device: AudioDeviceInfo, mixerBuffer: UInt32) -> OwnClock? {
        // Small device buffers keep the added latency down; Bluetooth decides for itself.
        if !device.isBluetooth, let minimum = CoreAudioHAL.minimumBufferFrames(device.id) {
            CoreAudioHAL.setUInt32(device.id, kAudioDevicePropertyBufferFrameSize, max(minimum, 128))
        }
        let rate = CoreAudioHAL.float64(device.id, kAudioDevicePropertyNominalSampleRate)
        guard rate > 0, CoreAudioHAL.unsupportedFormat(device.id, kAudioObjectPropertyScopeInput) == nil else { return nil }
        let deviceBuffer = Double(CoreAudioHAL.uint32(device.id, kAudioDevicePropertyBufferFrameSize))
        // Device audio arrives a buffer at a time while the mixer takes small, steady bites; hold
        // enough to ride out both, plus 2 ms of scheduling jitter.
        let headroom = 1.5 * deviceBuffer + 2 * Double(mixerBuffer) * rate / 48_000 + 0.002 * rate
        guard let source = AudioCoreAsyncCreate(Int32(device.usableInputChannels), rate, 48_000, UInt32(headroom.rounded(.up))) else {
            return nil
        }
        var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcID(device.id, AudioCoreAsyncIOProc, UnsafeMutableRawPointer(source), &proc) == noErr, let proc else {
            AudioCoreAsyncDestroy(source)
            return nil
        }
        guard AudioDeviceStart(device.id, proc) == noErr else {
            AudioDeviceDestroyIOProcID(device.id, proc)
            AudioCoreAsyncDestroy(source)
            return nil
        }
        let frames = Double(CoreAudioHAL.fixedLatencyFrames(device.id, kAudioObjectPropertyScopeInput))
            + deviceBuffer + headroom + Double(AudioCoreAsyncLookahead(source))
        return OwnClock(device: device, proc: proc, source: source, rate: rate, latencyMs: frames / rate * 1000)
    }

    func ownClockStats() -> [(name: String, rate: Double, stats: AudioCoreAsyncStats)] {
        ownClock.map { own in
            var stats = AudioCoreAsyncStats()
            AudioCoreAsyncReadStats(own.source, &stats)
            return (own.device.name, own.rate, stats)
        }
    }

    /// After an audio service restart the old objects no longer exist; drop them without calls.
    /// Async sources are leaked rather than freed, in case an IO thread is still winding down.
    func forget() {
        procID = nil
        aggregate = 0
        ownClock = []
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
        // The mixer has stopped; once each device's IOProc is destroyed nothing touches the sources.
        for own in ownClock {
            AudioDeviceStop(own.device.id, own.proc)
            AudioDeviceDestroyIOProcID(own.device.id, own.proc)
        }
        if let core { AudioCoreSetAsyncSources(core, nil, 0) }
        for own in ownClock { AudioCoreAsyncDestroy(own.source) }
        ownClock = []
    }
}
