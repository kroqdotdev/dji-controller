import Testing
@testable import Lavboard

/// Frames below were captured from a DJI Mic Mini 2S receiver (firmware 30.00.03.00).
struct ProtocolTests {
    static func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    @Test func decodesPingAcknowledgement() throws {
        let frame = try #require(DUMLFrame(bytes: Self.bytes("550d04335a020130800000761c")))
        #expect(frame.sender == 0x5A)
        #expect(frame.receiver == 0x02)
        #expect(frame.seq == 0x3001)
        #expect(frame.isResponse)
        #expect(frame.payload.isEmpty)
    }

    @Test func encodingRoundTrips() {
        let ack = Self.bytes("550d04335a020130800000761c")
        let frame = DUMLFrame(sender: 0x5A, receiver: 0x02, seq: 0x3001, type: 0x80, cmdSet: 0, cmdID: 0, payload: [])
        #expect(frame.encoded() == ack)
    }

    @Test func rejectsCorruptFrame() {
        var ack = Self.bytes("550d04335a020130800000761c")
        ack[9] ^= 0xFF
        #expect(DUMLFrame(bytes: ack) == nil)
    }

    @Test func parserReassemblesSplitAndJoinedFrames() {
        let status = Self.bytes("551704385a02d4c9005b0303070005020000000100b9ad")
        let heartbeat = Self.bytes("550e04665a02b4c9005b040ce1b1")
        var parser = DUMLParser()
        let stream = [0x00, 0x55] + status + heartbeat
        var frames = parser.feed(Array(stream[0..<10]))
        frames += parser.feed(Array(stream[10...]))
        #expect(frames.count == 2)
        #expect(frames[0].cmdID == 0x03)
        #expect(frames[1].cmdID == 0x04)
    }

    @Test func decodesReceiverAndTransmitterStatus() throws {
        let raw = Self.bytes("555604675a02d4f1005b03034600030000000020a8310000000000000000000000000000000000000f000000020000001200000002020000001ab025044900780000dd00dd000000000000000000000000000000776a")
        let frame = try #require(DUMLFrame(bytes: raw))
        let records = MicRecord.parse(payload: frame.payload)
        #expect(records.count == 2)

        let rx = try #require(ReceiverStatus(value: records[0].value))
        #expect(rx.mode == .mono)
        #expect(rx.batteryLevel == 1)
        #expect(rx.charging)
        #expect(rx.connectedMask == 0x02)

        #expect(records[1].field == 0x02)
        #expect(records[1].device == 0x02)
        let tx = try #require(TransmitterStatus(value: records[1].value))
        #expect(tx.gainDB == 0)
        #expect(tx.noise == .strong)
        #expect(!tx.lowCut)
        #expect(!tx.recording)
        #expect(tx.recordingHoursLeft == 22.1)
    }

    @Test func decodesAudioLevelRecord() throws {
        let frame = try #require(DUMLFrame(bytes: Self.bytes("551704385a02d4c9005b0303070005020000000100b9ad")))
        let records = MicRecord.parse(payload: frame.payload)
        #expect(records == [MicRecord(field: 0x05, device: 0x02, value: [0x00])])
    }

    @Test func encodesGainCommandForThirdTransmitter() {
        let payload = MicProtocol.setParamPayload(target: MicProtocol.slotMasks[2], param: .gain, value: [3])
        #expect(payload == [0x02, 0x04, 0x00, 0x00, 0x00, 0x39, 0x00, 0x01, 0x03])
        let negative = MicProtocol.setParamPayload(target: 0x01, param: .gain, value: [UInt8(bitPattern: -12)])
        #expect(negative.last == 0xF4)
    }

    @Test func gainStatusDecodesNegativeValues() throws {
        var value = Self.bytes("b025044900780000dd00dd000000000000000000000000000000")
        value[7] = UInt8(bitPattern: -7)
        #expect(try #require(TransmitterStatus(value: value)).gainDB == -7)
    }
}
