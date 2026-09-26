import Foundation

/// Chime data message on topic `photo` (SPEC §3.10). Must stay under 2 KB.
public struct PhotoShareMessage: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case offer, ready, end, cancel }

    public static let topic = "photo"
    public static let lifetimeMs: Int32 = 10_000
    public static let maxBytes = 2048

    public var v: Int = 1
    public var type: Kind
    public var seq: Int
    public var shareId: String
    public var senderId: String
    public var durationMs: Int?
    public var queueIndex: Int?
    public var queueLength: Int?

    public init(type: Kind, seq: Int, shareId: String, senderId: String, durationMs: Int? = nil, queueIndex: Int? = nil, queueLength: Int? = nil) {
        self.type = type
        self.seq = seq
        self.shareId = shareId
        self.senderId = senderId
        self.durationMs = durationMs
        self.queueIndex = queueIndex
        self.queueLength = queueLength
    }

    public enum CodecError: Error { case tooLarge(Int), unsupportedVersion(Int) }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let data = try e.encode(self)
        guard data.count <= Self.maxBytes else { throw CodecError.tooLarge(data.count) }
        return data
    }

    public static func decode(_ data: Data) throws -> PhotoShareMessage {
        let m = try JSONDecoder().decode(PhotoShareMessage.self, from: data)
        guard m.v == 1 else { throw CodecError.unsupportedVersion(m.v) }
        return m
    }
}

/// A data message as delivered by Chime: payload plus the server timestamp used for ordering.
public struct ReceivedPhotoMessage: Hashable, Sendable {
    public var message: PhotoShareMessage
    public var timestampMs: Int64

    public init(message: PhotoShareMessage, timestampMs: Int64) {
        self.message = message
        self.timestampMs = timestampMs
    }

    /// Order by Chime server timestamp, tiebreak by senderId (SPEC §3.10).
    public static func ordered(_ messages: [ReceivedPhotoMessage]) -> [ReceivedPhotoMessage] {
        messages.sorted {
            if $0.timestampMs != $1.timestampMs { return $0.timestampMs < $1.timestampMs }
            return $0.message.senderId < $1.message.senderId
        }
    }
}
