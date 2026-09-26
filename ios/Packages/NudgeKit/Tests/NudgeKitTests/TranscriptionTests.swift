import Foundation
import Testing
@testable import Transcription

@Suite("CRC32")
struct CRC32Tests {
    @Test func checkValue() { #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926) }
    @Test func empty() { #expect(CRC32.checksum([UInt8]()) == 0) }
}

@Suite("AWS event-stream codec")
struct EventStreamTests {
    /// aws-c-event-stream test vector `encoded/positive/empty_message`.
    @Test func emptyMessageVector() throws {
        let expected: [UInt8] = [0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x05, 0xC2, 0x48, 0xEB, 0x7D, 0x98, 0xC8, 0xFF]
        let m = EventStreamMessage(headers: [], payload: Data())
        #expect([UInt8](m.encoded()) == expected)
        #expect(try EventStreamMessage.decode(Data(expected)) == m)
    }

    /// aws-c-event-stream `encoded/positive/all_headers` payload-less subset: a string header.
    @Test func roundTripAudioEvent() throws {
        let pcm = Data((0..<3200).map { UInt8($0 % 251) })
        let m = EventStreamMessage.audioEvent(pcm)
        let decoded = try EventStreamMessage.decode(m.encoded())
        #expect(decoded == m)
        #expect(decoded.header(":event-type") == "AudioEvent")
        #expect(decoded.header(":message-type") == "event")
        #expect(decoded.payload == pcm)
    }

    @Test func detectsCorruption() {
        var bytes = [UInt8](EventStreamMessage.audioEvent(Data([1, 2, 3])).encoded())
        bytes[bytes.count - 6] ^= 0xFF
        #expect(throws: EventStreamMessage.DecodeError.messageCRC) { try EventStreamMessage.decode(Data(bytes)) }
        var prelude = [UInt8](EventStreamMessage.audioEvent(Data([1])).encoded())
        prelude[9] ^= 0x01
        #expect(throws: EventStreamMessage.DecodeError.preludeCRC) { try EventStreamMessage.decode(Data(prelude)) }
    }

    @Test func parsesTranscriptEvent() throws {
        let json = #"{"Transcript":{"Results":[{"Alternatives":[{"Transcript":"that hike last weekend","Items":[]}],"EndTime":3.2,"IsPartial":false,"ResultId":"r1","StartTime":1.0},{"Alternatives":[{"Transcript":"partial"}],"EndTime":4,"IsPartial":true,"ResultId":"r2","StartTime":3.5}]}}"#
        let m = EventStreamMessage(headers: [(":message-type", .string("event")), (":event-type", .string("TranscriptEvent")), (":content-type", .string("application/json"))], payload: Data(json.utf8))
        let segs = try TranscriptParser.finals(from: EventStreamMessage.decode(m.encoded()))
        #expect(segs == [FinalSegment(id: "r1", text: "that hike last weekend", startMs: 1000, endMs: 3200)])
    }

    @Test func exceptionThrows() {
        let m = EventStreamMessage(headers: [(":message-type", .string("exception")), (":exception-type", .string("BadRequestException"))], payload: Data("{\"Message\":\"bad\"}".utf8))
        #expect(throws: TranscriptionError.self) { try TranscriptParser.finals(from: m) }
    }
}

@Suite("Transcript batching")
struct TranscriptBatcherTests {
    @Test func mergesAdjacentFinalSegments() async {
        let collector = SegmentCollector()
        let batcher = TranscriptBatcher(delay: .seconds(60)) { await collector.append($0) }
        await batcher.append(TranscriptSegment(callId: "c", segId: "one", text: "remember the", startMs: 0, endMs: 500, clientTs: 1))
        await batcher.append(TranscriptSegment(callId: "c", segId: "two", text: "restaurant with lanterns", startMs: 550, endMs: 1_200, clientTs: 2))
        await batcher.flush()
        let sent = await collector.values
        #expect(sent.count == 1)
        #expect(sent.first?.text == "remember the restaurant with lanterns")
    }

    @Test func flushesWhenThereIsASpeechGap() async {
        let collector = SegmentCollector()
        let batcher = TranscriptBatcher(delay: .seconds(60)) { await collector.append($0) }
        await batcher.append(TranscriptSegment(callId: "c", segId: "one", text: "we went hiking", startMs: 0, endMs: 500, clientTs: 1))
        await batcher.append(TranscriptSegment(callId: "c", segId: "two", text: "anyway", startMs: 4_000, endMs: 4_200, clientTs: 2))
        await batcher.flush()
        #expect((await collector.values).map(\.text) == ["we went hiking", "anyway"])
    }
}

private actor SegmentCollector {
    var values: [TranscriptSegment] = []
    func append(_ segment: TranscriptSegment) { values.append(segment) }
}

@Suite("SigV4")
struct SigV4Tests {
    /// AWS docs "Deriving the signing key" example (IAM, 20120215).
    @Test func signingKeyVector() {
        let key = SigV4.signingKey(secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", day: "20120215", region: "us-east-1", service: "iam")
        #expect(key.hexString == "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d")
    }

    /// AWS docs "Authenticating Requests: Using Query Parameters (AWS Signature Version 4)" S3 GET example.
    @Test func s3PresignedURLVector() {
        let creds = AWSCredentials(accessKeyId: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        let date = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z
        let url = SigV4.presign(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!, credentials: creds,
                                region: "us-east-1", service: "s3", date: date, expires: 86400, payloadHash: SigV4.unsignedPayload)
        #expect(url.query()?.hasSuffix("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404") == true)
        #expect(url.absoluteString.contains("X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"))
    }

    @Test func transcribeURLShape() {
        let creds = AWSCredentials(accessKeyId: "AKID", secretAccessKey: "secret", sessionToken: "tok/en+=")
        let url = SigV4.presign(url: TranscribeStreamClient.streamURL(region: "us-east-1"), credentials: creds, region: "us-east-1",
                                service: "transcribe", date: Date(timeIntervalSince1970: 1_800_000_000), expires: 300)
        let s = url.absoluteString
        #expect(s.hasPrefix("wss://transcribestreaming.us-east-1.amazonaws.com:8443/stream-transcription-websocket?"))
        #expect(s.contains("X-Amz-Security-Token=tok%2Fen%2B%3D"))
        #expect(s.contains("media-encoding=pcm") && s.contains("sample-rate=16000") && s.contains("language-code=en-US"))
        #expect(s.contains("X-Amz-SignedHeaders=host"))
    }

    @Test func canonicalQuerySortsAndEncodes() {
        #expect(SigV4.canonicalQueryString([("b", "2"), ("a", "x y"), ("a", "1")]) == "a=1&a=x%20y&b=2")
        #expect(SigV4.uriEncode("a/b~c") == "a%2Fb~c")
    }
}
