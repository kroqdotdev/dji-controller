import CoreAudio
import Foundation
import MicSystemKit

struct AudioDeviceInfo: Identifiable, Hashable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var modelUID: String
    var inputChannels: Int
    var outputChannels: Int
    var transportType: UInt32 = 0
    var supports48k = true
    var nominalRate: Double = 48_000

    /// What mic system modules see when matching their receiver.
    var description: AudioDeviceDescription {
        AudioDeviceDescription(uid: uid, name: name, modelUID: modelUID, inputChannels: inputChannels)
    }
    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
    /// Devices that can run inside the 48 kHz engine as a clocked, sample-aligned source.
    var canJoinEngine: Bool { supports48k && !isBluetooth }
    /// Everything else with inputs runs on its own clock and is resampled.
    var runsOnOwnClock: Bool { !canJoinEngine }
    /// Input channels a track can use: an own-clock device captures its first eight.
    var usableInputChannels: Int { runsOnOwnClock ? min(inputChannels, Int(AC_ASYNC_MAX_CHANNELS)) : inputChannels }
}

/// Thin wrappers over the CoreAudio HAL property API.
enum CoreAudioHAL {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Every audio device except those in `skipping`, which are never queried: a device the engine
    /// is still setting up can block property reads for as long as coreaudiod takes.
    static func devices(skipping: Set<AudioObjectID> = []) -> [AudioDeviceInfo] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { !skipping.contains($0) }.compactMap { id in
            // Skip Lavboard's own aggregate before touching it: while the engine queue is setting
            // it up, its other properties can block for as long as coreaudiod takes.
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix(EngineSession.uidPrefix) else { return nil }
            return AudioDeviceInfo(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                                   modelUID: string(id, kAudioDevicePropertyModelUID) ?? "",
                                   inputChannels: bufferLayout(id, kAudioObjectPropertyScopeInput).reduce(0, +),
                                   outputChannels: bufferLayout(id, kAudioObjectPropertyScopeOutput).reduce(0, +),
                                   transportType: uint32(id, kAudioDevicePropertyTransportType),
                                   supports48k: supportsRate(id, 48_000),
                                   nominalRate: float64(id, kAudioDevicePropertyNominalSampleRate))
        }
    }

    static func availableRates(_ id: AudioObjectID) -> [ClosedRange<Double>] {
        var addr = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges.filter { $0.mMaximum >= $0.mMinimum }.map { $0.mMinimum...$0.mMaximum }
    }

    static func supportsRate(_ id: AudioObjectID, _ rate: Float64) -> Bool {
        availableRates(id).contains { $0.contains(rate) }
    }

    /// The rate to run an own-clock device at: the highest it offers up to 48 kHz (closest to the
    /// engine, least resampling), or its lowest rate if all are higher.
    static func preferredRate(among ranges: [ClosedRange<Double>]) -> Double? {
        let below = ranges.filter { $0.lowerBound <= 48_000 }.map { min($0.upperBound, 48_000) }
        return below.max() ?? ranges.map(\.lowerBound).min()
    }

    static func float64(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double {
        var addr = address(selector)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    /// The rate an input IOProc on the device receives: its first input stream's virtual format,
    /// or the nominal rate if that can't be read.
    static func inputRate(_ id: AudioObjectID) -> Double {
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size >= 4 {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / 4)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr, let first = streams.first {
                var fmtAddr = address(kAudioStreamPropertyVirtualFormat)
                var fmt = AudioStreamBasicDescription()
                var fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                if AudioObjectGetPropertyData(first, &fmtAddr, 0, nil, &fsize, &fmt) == noErr, fmt.mSampleRate > 0 {
                    return fmt.mSampleRate
                }
            }
        }
        return float64(id, kAudioDevicePropertyNominalSampleRate)
    }

    /// UID of the system's default output device.
    static func defaultOutputUID() -> String? {
        let id = uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        return id == 0 ? nil : string(id, kAudioDevicePropertyDeviceUID)
    }

    /// Smallest IO buffer the device allows, in frames.
    static func minimumBufferFrames(_ id: AudioObjectID) -> UInt32? {
        var addr = address(kAudioDevicePropertyBufferFrameSizeRange)
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &range) == noErr, range.mMinimum > 0 else { return nil }
        return UInt32(range.mMinimum)
    }

    /// The device's own input gain, in dB, when the system lets apps change it (many USB mics do).
    static func inputGain(_ id: AudioObjectID) -> (value: Double, range: ClosedRange<Double>)? {
        var addr = address(kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeInput)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &addr),
              AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue else { return nil }
        var db: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &db) == noErr else { return nil }
        var rangeAddr = address(kAudioDevicePropertyVolumeRangeDecibels, kAudioObjectPropertyScopeInput)
        var range = AudioValueRange()
        size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &rangeAddr, 0, nil, &size, &range) == noErr, range.mMaximum > range.mMinimum else { return nil }
        return (Double(db), range.mMinimum...range.mMaximum)
    }

    static func setInputGain(_ id: AudioObjectID, dB: Double) {
        var addr = address(kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeInput)
        var value = Float32(dB)
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
        var addr = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    @discardableResult
    static func setUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: UInt32) -> OSStatus {
        var addr = address(selector)
        var v = value
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    @discardableResult
    static func setSampleRate(_ id: AudioObjectID, _ rate: Float64) -> OSStatus {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var v = rate
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &v)
    }

    /// Channels per stream (one entry per IOProc buffer) for a scope.
    static func bufferLayout(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [Int] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// Fixed latency of a device in one direction, in frames: device + safety offset + first stream.
    static func fixedLatencyFrames(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> UInt32 {
        var streamLatency: UInt32 = 0
        var addr = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size >= 4 {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / 4)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr, let first = streams.first {
                streamLatency = uint32(first, kAudioStreamPropertyLatency)
            }
        }
        return uint32(id, kAudioDevicePropertyLatency, scope) + uint32(id, kAudioDevicePropertySafetyOffset, scope) + streamLatency
    }

    /// Returns a description of the first stream whose IOProc format is not interleaved Float32,
    /// or nil if every stream in the scope (possibly none) is usable.
    static func unsupportedFormat(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> String? {
        var addr = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size >= 4 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / 4)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr else { return "unreadable streams" }
        for stream in streams {
            var fmtAddr = address(kAudioStreamPropertyVirtualFormat)
            var fmt = AudioStreamBasicDescription()
            var fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(stream, &fmtAddr, 0, nil, &fsize, &fmt) == noErr else { return "unreadable format" }
            let ok = fmt.mFormatID == kAudioFormatLinearPCM && fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0
                && fmt.mBitsPerChannel == 32 && fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            if !ok {
                return "\(fmt.mBitsPerChannel)-bit, flags 0x\(String(fmt.mFormatFlags, radix: 16)), \(fmt.mChannelsPerFrame) ch"
            }
        }
        return nil
    }
}
