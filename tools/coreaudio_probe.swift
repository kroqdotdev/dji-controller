// Enumerates the CoreAudio properties of the DJI receiver and reports which are settable.
import CoreAudio
import Foundation

func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
}

func getArray<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ t: T.Type) -> [T] {
    var a = a; var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    let n = Int(size) / MemoryLayout<T>.stride
    let p = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { p.deallocate() }
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, p) == noErr else { return [] }
    return (0..<n).map { p.load(fromByteOffset: $0 * MemoryLayout<T>.stride, as: T.self) }
}

func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = addr(sel); var s: Unmanaged<CFString>? = nil; var size = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &s) == noErr, let s else { return "?" }
    return s.takeRetainedValue() as String
}

func fourcc(_ v: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? String(v)
}

let devices = getArray(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDevices), AudioObjectID.self)
guard let dev = devices.first(where: { getString($0, kAudioObjectPropertyName).contains("Wireless Mic") }) else {
    print("receiver not found"); exit(1)
}
print("device id=\(dev) name=\(getString(dev, kAudioObjectPropertyName)) uid=\(getString(dev, kAudioDevicePropertyDeviceUID))")
print("model uid=\(getString(dev, kAudioDevicePropertyModelUID))")

let rates = getArray(dev, addr(kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange.self)
print("available rates: \(rates.map { "\($0.mMinimum)-\($0.mMaximum)" })")

let scope = kAudioObjectPropertyScopeInput
let checks: [(String, AudioObjectPropertySelector)] = [
    ("volumeScalar", kAudioDevicePropertyVolumeScalar),
    ("volumeDecibels", kAudioDevicePropertyVolumeDecibels),
    ("mute", kAudioDevicePropertyMute),
    ("dataSource", kAudioDevicePropertyDataSource),
    ("playThru", kAudioDevicePropertyPlayThru),
    ("clockSource", kAudioDevicePropertyClockSource),
]
for el in [kAudioObjectPropertyElementMain, 1, 2] {
    for (name, sel) in checks {
        var a = addr(sel, scope, el)
        guard AudioObjectHasProperty(dev, &a) else { continue }
        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(dev, &a, &settable)
        var size: UInt32 = 4; var f: Float32 = 0; var u: UInt32 = 0
        let val: String
        if name.hasPrefix("volume") {
            AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &f); val = String(f)
        } else {
            AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &u); val = name == "dataSource" ? fourcc(u) : String(u)
        }
        print("  element \(el) \(name) = \(val) settable=\(settable.boolValue)")
    }
}
var dbr = addr(kAudioDevicePropertyVolumeRangeDecibels, scope)
if AudioObjectHasProperty(dev, &dbr) {
    var r = AudioValueRange(); var size = UInt32(MemoryLayout<AudioValueRange>.size)
    AudioObjectGetPropertyData(dev, &dbr, 0, nil, &size, &r)
    print("  dB range: \(r.mMinimum) .. \(r.mMaximum)")
}

// Owned control objects (volume/mute/selector controls)
let controls = getArray(dev, addr(kAudioObjectPropertyOwnedObjects), AudioObjectID.self)
for c in controls {
    var ca = addr(kAudioObjectPropertyClass); var cls: AudioClassID = 0; var size: UInt32 = 4
    AudioObjectGetPropertyData(c, &ca, 0, nil, &size, &cls)
    var sa = addr(kAudioControlPropertyScope); var sc: UInt32 = 0
    AudioObjectGetPropertyData(c, &sa, 0, nil, &size, &sc)
    var ea = addr(kAudioControlPropertyElement); var e: UInt32 = 0
    AudioObjectGetPropertyData(c, &ea, 0, nil, &size, &e)
    print("  owned object \(c): class=\(fourcc(cls)) scope=\(fourcc(sc)) element=\(e)")
}
