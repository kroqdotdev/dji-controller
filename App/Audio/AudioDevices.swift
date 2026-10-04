import CoreAudio
import Foundation

struct AudioDeviceInfo: Identifiable, Hashable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var modelUID: String
    var inputChannels: Int
    var outputChannels: Int

    var isDJIReceiver: Bool { modelUID.contains("2CA3:4015") || modelUID.contains("2CA3:4115") }
}

/// Thin wrappers over the CoreAudio HAL property API.
enum CoreAudioHAL {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func devices() -> [AudioDeviceInfo] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioDeviceInfo(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                                   modelUID: string(id, kAudioDevicePropertyModelUID) ?? "",
                                   inputChannels: bufferLayout(id, kAudioObjectPropertyScopeInput).reduce(0, +),
                                   outputChannels: bufferLayout(id, kAudioObjectPropertyScopeOutput).reduce(0, +))
        }
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
