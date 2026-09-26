import Foundation

/// CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320) as used by the AWS event-stream framing.
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    public static func checksum<C: Collection>(_ bytes: C, seed: UInt32 = 0) -> UInt32 where C.Element == UInt8 {
        var crc = ~seed
        for b in bytes { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return ~crc
    }
}

/// AWS `application/vnd.amazon.eventstream` binary message.
public struct EventStreamMessage: Equatable, Sendable {
    public enum HeaderValue: Equatable, Sendable {
        case string(String)
        case bytes(Data)
        case bool(Bool)
        case int32(Int32)
    }

    public var headers: [(String, HeaderValue)]
    public var payload: Data

    public init(headers: [(String, HeaderValue)], payload: Data) {
        self.headers = headers
        self.payload = payload
    }

    public static func == (a: EventStreamMessage, b: EventStreamMessage) -> Bool {
        a.payload == b.payload && a.headers.count == b.headers.count
            && zip(a.headers, b.headers).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    public func header(_ name: String) -> String? {
        for (k, v) in headers where k == name {
            if case .string(let s) = v { return s }
        }
        return nil
    }

    public enum DecodeError: Error, Equatable {
        case tooShort, preludeCRC, messageCRC, lengthMismatch, badHeader
    }

    public func encoded() -> Data {
        var h = Data()
        for (name, value) in headers {
            let nameBytes = Array(name.utf8)
            h.append(UInt8(nameBytes.count))
            h.append(contentsOf: nameBytes)
            switch value {
            case .bool(let b): h.append(b ? 0 : 1)
            case .int32(let i):
                h.append(4)
                h.appendBE(UInt32(bitPattern: i))
            case .bytes(let d):
                h.append(6)
                h.appendBE(UInt16(d.count))
                h.append(d)
            case .string(let s):
                let bytes = Array(s.utf8)
                h.append(7)
                h.appendBE(UInt16(bytes.count))
                h.append(contentsOf: bytes)
            }
        }
        let total = 12 + h.count + payload.count + 4
        var out = Data()
        out.appendBE(UInt32(total))
        out.appendBE(UInt32(h.count))
        out.appendBE(CRC32.checksum(out))
        out.append(h)
        out.append(payload)
        out.appendBE(CRC32.checksum(out))
        return out
    }

    public static func decode(_ data: Data) throws -> EventStreamMessage {
        let bytes = [UInt8](data)
        guard bytes.count >= 16 else { throw DecodeError.tooShort }
        let total = Int(bytes.readBE32(0))
        let headersLen = Int(bytes.readBE32(4))
        guard total == bytes.count, headersLen + 16 <= total else { throw DecodeError.lengthMismatch }
        guard CRC32.checksum(bytes[0..<8]) == bytes.readBE32(8) else { throw DecodeError.preludeCRC }
        guard CRC32.checksum(bytes[0..<(total - 4)]) == bytes.readBE32(total - 4) else { throw DecodeError.messageCRC }

        var headers: [(String, HeaderValue)] = []
        var i = 12
        let headersEnd = 12 + headersLen
        while i < headersEnd {
            let nameLen = Int(bytes[i]); i += 1
            guard i + nameLen < headersEnd + 1 else { throw DecodeError.badHeader }
            let name = String(decoding: bytes[i..<(i + nameLen)], as: UTF8.self); i += nameLen
            let type = bytes[i]; i += 1
            switch type {
            case 0: headers.append((name, .bool(true)))
            case 1: headers.append((name, .bool(false)))
            case 4:
                headers.append((name, .int32(Int32(bitPattern: bytes.readBE32(i))))); i += 4
            case 6, 7:
                let len = Int(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])); i += 2
                let slice = bytes[i..<(i + len)]; i += len
                headers.append((name, type == 7 ? .string(String(decoding: slice, as: UTF8.self)) : .bytes(Data(slice))))
            case 2: i += 1
            case 3: i += 2
            case 5, 8: i += 8
            case 9: i += 16
            default: throw DecodeError.badHeader
            }
        }
        let payload = Data(bytes[headersEnd..<(total - 4)])
        return EventStreamMessage(headers: headers, payload: payload)
    }

    /// Transcribe streaming audio frame.
    public static func audioEvent(_ pcm: Data) -> EventStreamMessage {
        EventStreamMessage(headers: [
            (":content-type", .string("application/octet-stream")),
            (":event-type", .string("AudioEvent")),
            (":message-type", .string("event")),
        ], payload: pcm)
    }
}

extension Data {
    mutating func appendBE(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    mutating func appendBE(_ v: UInt16) {
        append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)])
    }
}

extension Array where Element == UInt8 {
    func readBE32(_ at: Int) -> UInt32 {
        UInt32(self[at]) << 24 | UInt32(self[at + 1]) << 16 | UInt32(self[at + 2]) << 8 | UInt32(self[at + 3])
    }
}
