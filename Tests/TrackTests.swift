import Foundation
import Testing
@testable import Lavboard

struct TrackTests {
    let devices = [
        BufferMap.SubDevice(uid: "dji", inputStreams: [4], outputStreams: []),
        BufferMap.SubDevice(uid: "webcam", inputStreams: [2], outputStreams: []),
        BufferMap.SubDevice(uid: "interface", inputStreams: [2, 2], outputStreams: [2]),
        BufferMap.SubDevice(uid: "speakers", inputStreams: [], outputStreams: [2]),
    ]

    @Test func mapsChannelsAcrossDevicesAndStreams() {
        #expect(BufferMap.input(channel: 3, of: "dji", in: devices)! == (buffer: 0, channel: 3))
        #expect(BufferMap.input(channel: 1, of: "webcam", in: devices)! == (buffer: 1, channel: 1))
        #expect(BufferMap.input(channel: 0, of: "interface", in: devices)! == (buffer: 2, channel: 0))
        #expect(BufferMap.input(channel: 3, of: "interface", in: devices)! == (buffer: 3, channel: 1))
        #expect(BufferMap.input(channel: 4, of: "interface", in: devices) == nil)
        #expect(BufferMap.input(channel: 0, of: "missing", in: devices) == nil)
        #expect(BufferMap.input(channel: -1, of: "webcam", in: devices) == nil)
    }

    @Test func findsEachDevicesFirstOutputBuffer() {
        #expect(BufferMap.firstOutput(of: "interface", in: devices) == 0)
        #expect(BufferMap.firstOutput(of: "speakers", in: devices) == 1)
        #expect(BufferMap.firstOutput(of: "webcam", in: devices) == nil)
    }

    @Test func migratesTheOldFourStripSettings() throws {
        let json = #"[{"name":"Glenn","color":"orange","faderDB":0.5,"sendToVenue":true},{"name":"Mic 2","sendToVenue":false},{"name":"Mic 3"},{"name":"Mic 4","color":"blue"}]"#
        let legacy = try JSONDecoder().decode([LegacyStripSettings].self, from: Data(json.utf8))
        let tracks = LegacyStripSettings.migrate(legacy)
        #expect(tracks.map(\.name) == ["Glenn", "Mic 2", "Mic 3", "Mic 4"])
        #expect(tracks.map(\.source) == (0..<4).map { .transmitter(system: "dji-mic-mini-2s", slot: $0) })
        #expect(tracks[0].color == .orange && tracks[0].faderDB == 0.5)
        #expect(tracks[1].sendToVenue == false && tracks[1].color == .white)
    }

    @Test func roundTripsAndToleratesMissingFields() throws {
        let original = [Track(name: "Webcam", color: .green, balance: -0.3,
                              source: .device(uid: "u1", name: "C922", channel: 0, stereo: true))]
        let decoded = try JSONDecoder().decode([Track].self, from: JSONEncoder().encode(original))
        #expect(decoded == original)

        let sparse = #"[{"name":"Host","source":{"transmitter":{"slot":2}}}]"#
        let track = try JSONDecoder().decode([Track].self, from: Data(sparse.utf8))[0]
        // Saved before mic systems were modules: it belongs to the DJI Mic Mini 2S.
        #expect(track.source == .transmitter(system: "dji-mic-mini-2s", slot: 2))
        #expect(track.faderDB == 0 && track.sendToVenue && track.color == .white)
    }

    @Test func defaultNamesAreShortEnoughForTape() {
        #expect(Track.defaultName(deviceName: "Lohsefar Microphone", channel: 0, stereo: false, deviceChannels: 1) == "Lohsefar")
        #expect(Track.defaultName(deviceName: "MacBook Pro Microphone", channel: 0, stereo: false, deviceChannels: 1) == "MacBook Pro")
        #expect(Track.defaultName(deviceName: "Sam\u{2019}s AirPods Pro", channel: 0, stereo: false, deviceChannels: 1) == "AirPods Pro")
        #expect(Track.defaultName(deviceName: "C922 Pro Stream Webcam", channel: 0, stereo: true, deviceChannels: 2) == "C922 Pro")
        #expect(Track.shortDeviceName("Realtek USB2.0 Audio") == "Realtek")
        #expect(Track.defaultName(deviceName: "C922 Pro Stream Webcam", channel: 0, stereo: true, deviceChannels: 2) == "C922 Pro")
        #expect(Track.defaultName(deviceName: "Realtek USB2.0 Audio", channel: 1, stereo: false, deviceChannels: 2) == "Realtek 2")
        #expect(Track.defaultName(deviceName: "Scarlett 18i20 USB", channel: 2, stereo: true, deviceChannels: 18) == "Scarlett 18i20 3+4")
        #expect(Track.defaultName(deviceName: "USB Audio", channel: 0, stereo: false, deviceChannels: 1) == "USB")
    }

    @Test func sourceIdentityIgnoresTheCachedDeviceName() {
        let a = TrackSource.device(uid: "u1", name: "Old name", channel: 2, stereo: false)
        let b = TrackSource.device(uid: "u1", name: "New name", channel: 2, stereo: false)
        #expect(a.identity == b.identity)
        #expect(a.identity != TrackSource.device(uid: "u1", name: "x", channel: 2, stereo: true).identity)
        #expect(TrackSource.device(uid: "u", name: "n", channel: 2, stereo: true).channelLabel == "In 3+4")
    }

    @Test func ownClockDevicesRunAtTheirBestRateUpTo48k() {
        let c922: [ClosedRange<Double>] = [16_000...16_000, 24_000...24_000, 32_000...32_000]
        #expect(CoreAudioHAL.preferredRate(among: c922) == 32_000)
        #expect(CoreAudioHAL.preferredRate(among: [44_100...44_100, 88_200...88_200]) == 44_100)
        #expect(CoreAudioHAL.preferredRate(among: [96_000...96_000, 192_000...192_000]) == 96_000)
        #expect(CoreAudioHAL.preferredRate(among: [8_000...96_000]) == 48_000)
        #expect(CoreAudioHAL.preferredRate(among: []) == nil)
    }

    @Test func transmitterSourcesRoundTripWithTheirSystem() throws {
        let sources: [TrackSource] = [.transmitter(system: "rode-wireless-pro", slot: 1),
                                      .device(uid: "u1", name: "C922", channel: 0, stereo: true)]
        let json = try JSONEncoder().encode(sources)
        #expect(try JSONDecoder().decode([TrackSource].self, from: json) == sources)
        #expect(String(decoding: json, as: UTF8.self).contains(#""system":"rode-wireless-pro""#))
        // The same slot on two systems is two different sources.
        #expect(TrackSource.transmitter(system: "a", slot: 0).identity != TrackSource.transmitter(system: "b", slot: 0).identity)
    }
}
