import Foundation

/// WebSocket server → client events (SPEC §3.8).
public enum ServerEvent: Sendable, Hashable {
    case nudgeUpdated(Nudge)
    case callMatched(callId: String, nudgeId: String)
    case callEnded(callId: String)
    case messageNew(friendId: String, message: Message)
    case friendRequest(PublicUser)
    case friendAccepted(PublicUser)
    case photoSuggestion(PhotoSuggestion)
    case callSummaryReady(callId: String, friendId: String)
    case pong
    case unknown(String)

    private struct Envelope: Decodable { let type: String }
    private struct NudgeBody: Decodable { let nudge: Nudge }
    private struct MatchBody: Decodable { let callId: String; let nudgeId: String }
    private struct CallBody: Decodable { let callId: String }
    private struct MessageBody: Decodable { let friendId: String; let message: Message }
    private struct UserBody: Decodable { let user: PublicUser }
    private struct SummaryBody: Decodable { let callId: String; let friendId: String }

    public static func decode(_ data: Data) throws -> ServerEvent {
        let d = NudgeJSON.decoder()
        let type = try d.decode(Envelope.self, from: data).type
        switch type {
        case "nudge.updated": return .nudgeUpdated(try d.decode(NudgeBody.self, from: data).nudge)
        case "call.matched":
            let b = try d.decode(MatchBody.self, from: data)
            return .callMatched(callId: b.callId, nudgeId: b.nudgeId)
        case "call.ended": return .callEnded(callId: try d.decode(CallBody.self, from: data).callId)
        case "message.new":
            let b = try d.decode(MessageBody.self, from: data)
            return .messageNew(friendId: b.friendId, message: b.message)
        case "friend.request": return .friendRequest(try d.decode(UserBody.self, from: data).user)
        case "friend.accepted": return .friendAccepted(try d.decode(UserBody.self, from: data).user)
        case "photo.suggestion": return .photoSuggestion(try d.decode(PhotoSuggestion.self, from: data))
        case "call.summary.ready":
            let b = try d.decode(SummaryBody.self, from: data)
            return .callSummaryReady(callId: b.callId, friendId: b.friendId)
        case "pong": return .pong
        default: return .unknown(type)
        }
    }
}

/// Client → server WebSocket actions.
public enum ClientAction: Sendable, Hashable {
    case ping
    case waiting(nudgeId: String?)
    case transcript(TranscriptSegment)

    public func encoded() throws -> Data {
        let e = NudgeJSON.encoder()
        switch self {
        case .ping:
            return try e.encode(["action": "ping"])
        case .waiting(let id):
            struct W: Encodable { let action = "waiting"; let nudgeId: String?
                func encode(to encoder: Encoder) throws {
                    var c = encoder.container(keyedBy: K.self)
                    try c.encode(action, forKey: .action)
                    try c.encode(nudgeId, forKey: .nudgeId) // explicit null = left waiting room
                }
                enum K: String, CodingKey { case action, nudgeId }
            }
            return try e.encode(W(nudgeId: id))
        case .transcript(let seg):
            return try e.encode(seg)
        }
    }
}

public struct TranscriptSegment: Codable, Sendable, Hashable {
    public var action: String = "transcript"
    public var callId: String
    public var segId: String
    public var text: String
    public var startMs: Int
    public var endMs: Int
    public var clientTs: Int64

    public init(callId: String, segId: String, text: String, startMs: Int, endMs: Int, clientTs: Int64) {
        self.callId = callId
        self.segId = segId
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.clientTs = clientTs
    }
}

/// Push payload `type` values (SPEC §3.9).
public enum PushKind: String, Sendable {
    case nudge
    case availabilityCheck = "availability.check"
    case nudgeCleanup = "nudge.cleanup"
    case calendarSync = "calendar.sync"
    case callIncoming = "call.incoming"
    case messageNew = "message.new"
    case friendRequest = "friend.request"
    case friendAccepted = "friend.accepted"
    case availabilityStale = "availability.stale"
}

public enum NotificationIDs {
    public static let nudgeCategory = "NUDGE"
    public static let messageCategory = "MESSAGE"
    public static let accept = "ACCEPT"
    public static let skip = "SKIP"
    public static let less = "LESS"
}
