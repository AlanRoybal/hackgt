import Foundation

// Wire types mirroring docs/SPEC.md §3.7. Field names match the JSON exactly.

public struct PublicUser: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var handle: String
    public var displayName: String
    public var avatarUrl: URL?

    public init(id: String, handle: String, displayName: String, avatarUrl: URL? = nil) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarUrl = avatarUrl
    }
}

public enum Frequency: String, Codable, Sendable, CaseIterable {
    case off, low, normal, high

    public var title: String {
        switch self {
        case .off: "Off"
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }

    public var explanation: String {
        switch self {
        case .off: "No nudges. You can still call from a friend's profile."
        case .low: "At most one a day, and rarely the same person twice in a row."
        case .normal: "Up to three a day, spaced a couple of hours apart."
        case .high: "Up to six a day when you and your friends are often free."
        }
    }

    /// One step down, flooring at Low (SPEC §3.6: only Settings can choose Off).
    public var lessOften: Frequency {
        switch self {
        case .high: .normal
        case .normal: .low
        case .low, .off: self
        }
    }
}

public enum SkipBehavior: String, Codable, Sendable, CaseIterable {
    case message, nothing
}

public enum PhotoMode: String, Codable, Sendable, CaseIterable {
    case ask, auto, off

    public var title: String {
        switch self {
        case .ask: "Ask first"
        case .auto: "Automatic"
        case .off: "Off"
        }
    }
}

public struct Settings: Codable, Sendable, Hashable {
    public var frequency: Frequency
    public var quietStart: String
    public var quietEnd: String
    public var minWindowMin: Int
    public var respectFocus: Bool
    public var respectDriving: Bool
    public var skipBehavior: SkipBehavior
    public var photoMode: PhotoMode
    public var photoIndexing: Bool
    public var includeScreenshots: Bool
    public var memoryEnabled: Bool

    public init(
        frequency: Frequency = .normal, quietStart: String = "00:00", quietEnd: String = "08:00",
        minWindowMin: Int = 5, respectFocus: Bool = true, respectDriving: Bool = true,
        skipBehavior: SkipBehavior = .message, photoMode: PhotoMode = .ask, photoIndexing: Bool = true,
        includeScreenshots: Bool = false, memoryEnabled: Bool = true
    ) {
        self.frequency = frequency
        self.quietStart = quietStart
        self.quietEnd = quietEnd
        self.minWindowMin = minWindowMin
        self.respectFocus = respectFocus
        self.respectDriving = respectDriving
        self.skipBehavior = skipBehavior
        self.photoMode = photoMode
        self.photoIndexing = photoIndexing
        self.includeScreenshots = includeScreenshots
        self.memoryEnabled = memoryEnabled
    }

    public static let `default` = Settings()
}

public struct UserDTO: Codable, Sendable, Hashable {
    public var id: String
    public var handle: String
    public var displayName: String
    public var avatarUrl: URL?
    public var settings: Settings
    public var tz: String
    public var phoneVerified: Bool
    public var tosVersion: String?
    public var tosAcceptedAt: Date?

    public init(
        id: String, handle: String, displayName: String, avatarUrl: URL? = nil, settings: Settings = .default,
        tz: String = TimeZone.current.identifier, phoneVerified: Bool = false, tosVersion: String? = nil,
        tosAcceptedAt: Date? = nil
    ) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.settings = settings
        self.tz = tz
        self.phoneVerified = phoneVerified
        self.tosVersion = tosVersion
        self.tosAcceptedAt = tosAcceptedAt
    }

    public var publicUser: PublicUser {
        PublicUser(id: id, handle: handle, displayName: displayName, avatarUrl: avatarUrl)
    }
}

public struct MeResponse: Codable, Sendable, Hashable {
    public var user: UserDTO
    public var needsTos: Bool
    public var needsHandle: Bool
    public var currentTosVersion: String

    public init(user: UserDTO, needsTos: Bool, needsHandle: Bool, currentTosVersion: String) {
        self.user = user
        self.needsTos = needsTos
        self.needsHandle = needsHandle
        self.currentTosVersion = currentTosVersion
    }
}

public struct SettingsPatch: Codable, Sendable {
    public var frequency: Frequency?
    public var quietStart: String?
    public var quietEnd: String?
    public var minWindowMin: Int?
    public var respectFocus: Bool?
    public var respectDriving: Bool?
    public var skipBehavior: SkipBehavior?
    public var photoMode: PhotoMode?
    public var photoIndexing: Bool?
    public var includeScreenshots: Bool?
    public var memoryEnabled: Bool?

    public init() {}

    /// A patch that sets every field — used when saving a whole edited Settings value.
    public init(_ s: Settings) {
        frequency = s.frequency
        quietStart = s.quietStart
        quietEnd = s.quietEnd
        minWindowMin = s.minWindowMin
        respectFocus = s.respectFocus
        respectDriving = s.respectDriving
        skipBehavior = s.skipBehavior
        photoMode = s.photoMode
        photoIndexing = s.photoIndexing
        includeScreenshots = s.includeScreenshots
        memoryEnabled = s.memoryEnabled
    }
}

public struct MePatch: Codable, Sendable {
    public var displayName: String?
    public var tz: String?
    public var avatarKey: String?
    public var settings: SettingsPatch?

    public init(displayName: String? = nil, tz: String? = nil, avatarKey: String? = nil, settings: SettingsPatch? = nil) {
        self.displayName = displayName
        self.tz = tz
        self.avatarKey = avatarKey
        self.settings = settings
    }
}

public struct Friend: Codable, Sendable, Hashable, Identifiable {
    public var user: PublicUser
    public var nickname: String?
    public var since: Date
    public var lastCallAt: Date?
    public var freeNow: Bool
    public var freeUntil: Date?
    /// When the current busy stretch ends; nil when free or when the server has nothing fresh.
    public var busyUntil: Date?

    public var id: String { user.id }
    /// The name this viewer sees everywhere: their private nickname, else the display name.
    public var name: String { nickname?.nonEmpty ?? user.displayName }

    public init(user: PublicUser, nickname: String? = nil, since: Date, lastCallAt: Date? = nil, freeNow: Bool = false, freeUntil: Date? = nil, busyUntil: Date? = nil) {
        self.user = user
        self.nickname = nickname
        self.since = since
        self.lastCallAt = lastCallAt
        self.freeNow = freeNow
        self.freeUntil = freeUntil
        self.busyUntil = busyUntil
    }

    /// The next moment this status stops being true: the free window closing or the busy stretch ending.
    public var statusChangesAt: Date? { freeNow ? freeUntil : busyUntil }

    /// Compact, date-aware text shared by cards, rows, and profiles (e.g. "Sun 3 PM").
    public func freeUntilText(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let until = freeUntil else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: until)).day ?? 0
        let day = days == 0 ? "" : (days > 0 && days < 7 ? "EEE" : "MMMd")
        let time = calendar.component(.minute, from: until) == 0 ? "j" : "jm"
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(day + time)
        return formatter.string(from: until)
    }
}

public enum Relation: String, Codable, Sendable {
    case none, requested, incoming, friends, blocked
}

/// What this phone hands to the other one when they're held together (ACC-13).
public struct TapToken: Codable, Sendable, Hashable {
    public var token: String
    public var expiresAt: Date

    public init(token: String, expiresAt: Date) {
        self.token = token
        self.expiresAt = expiresAt
    }
}

public struct TapResult: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        /// Only this phone's tap has landed so far; ask again.
        case pending
        /// Friends because of this tap.
        case friends
        /// Were already friends; nothing changed.
        case alreadyFriends = "already_friends"
    }

    public var status: Status
    /// Who they are, once they're friends (never while pending).
    public var user: PublicUser?

    public init(status: Status, user: PublicUser?) {
        self.status = status
        self.user = user
    }
}

public struct SearchResult: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var handle: String
    public var displayName: String
    public var avatarUrl: URL?
    public var relation: Relation

    public init(id: String, handle: String, displayName: String, avatarUrl: URL? = nil, relation: Relation) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.relation = relation
    }

    public var publicUser: PublicUser { PublicUser(id: id, handle: handle, displayName: displayName, avatarUrl: avatarUrl) }
}

public struct FriendRequestEntry: Codable, Sendable, Hashable, Identifiable {
    public var user: PublicUser
    public var createdAt: Date
    public var id: String { user.id }

    public init(user: PublicUser, createdAt: Date) {
        self.user = user
        self.createdAt = createdAt
    }
}

public struct FriendRequests: Codable, Sendable, Hashable {
    public var incoming: [FriendRequestEntry]
    public var outgoing: [FriendRequestEntry]

    public init(incoming: [FriendRequestEntry] = [], outgoing: [FriendRequestEntry] = []) {
        self.incoming = incoming
        self.outgoing = outgoing
    }
}

public enum NudgeState: String, Codable, Sendable {
    case precheck, pending
    case acceptedByOne = "accepted_by_one"
    case matched
    case inCall = "in_call"
    case ended, skipped, expired, cancelled

    public var isTerminal: Bool {
        switch self {
        case .ended, .skipped, .expired, .cancelled: true
        default: false
        }
    }
}

public enum NudgeResponse: String, Codable, Sendable {
    case accepted, skipped, less, expired
}

public enum NudgeAction: String, Codable, Sendable {
    case accept, skip, less
}

public struct TimeWindow: Codable, Sendable, Hashable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public struct TopicRef: Codable, Sendable, Hashable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct Nudge: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case auto, direct }

    public var id: String
    public var kind: Kind
    public var friend: PublicUser
    public var nickname: String?
    public var state: NudgeState
    public var myResponse: NudgeResponse?
    public var theirResponse: NudgeResponse?
    public var window: TimeWindow
    public var minutes: Int
    public var title: String
    public var body: String
    public var topic: TopicRef?
    public var expiresAt: Date?
    public var callId: String?
    /// My drafted follow-up waiting for approval after I skipped (NUD-12). Never set for the other person.
    public var followUpDraft: String?

    public var friendName: String { nickname?.nonEmpty ?? friend.displayName }

    public init(
        id: String, kind: Kind = .auto, friend: PublicUser, nickname: String? = nil, state: NudgeState,
        myResponse: NudgeResponse? = nil, theirResponse: NudgeResponse? = nil, window: TimeWindow, minutes: Int,
        title: String, body: String, topic: TopicRef? = nil, expiresAt: Date? = nil, callId: String? = nil,
        followUpDraft: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.friend = friend
        self.nickname = nickname
        self.state = state
        self.myResponse = myResponse
        self.theirResponse = theirResponse
        self.window = window
        self.minutes = minutes
        self.title = title
        self.body = body
        self.topic = topic
        self.expiresAt = expiresAt
        self.callId = callId
        self.followUpDraft = followUpDraft
    }
}

public struct Message: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case user
        case autoFollowup = "auto_followup"
        case system
    }

    public var id: String
    public var friendId: String
    public var senderId: String
    public var body: String
    public var kind: Kind
    public var createdAt: Date

    public init(id: String, friendId: String, senderId: String, body: String, kind: Kind, createdAt: Date) {
        self.id = id
        self.friendId = friendId
        self.senderId = senderId
        self.body = body
        self.kind = kind
        self.createdAt = createdAt
    }
}

public struct Conversation: Codable, Sendable, Hashable, Identifiable {
    public var friend: PublicUser
    public var nickname: String?
    public var lastMessage: Message?
    public var unread: Int

    public var id: String { friend.id }
    public var name: String { nickname?.nonEmpty ?? friend.displayName }

    public init(friend: PublicUser, nickname: String? = nil, lastMessage: Message? = nil, unread: Int = 0) {
        self.friend = friend
        self.nickname = nickname
        self.lastMessage = lastMessage
        self.unread = unread
    }
}

public struct Topic: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case open, suggested, used, dismissed }

    public var id: String
    public var title: String
    public var aboutUserId: String
    public var summary: String
    public var followUpAfter: Date?
    public var status: Status

    public init(id: String, title: String, aboutUserId: String, summary: String, followUpAfter: Date? = nil, status: Status = .open) {
        self.id = id
        self.title = title
        self.aboutUserId = aboutUserId
        self.summary = summary
        self.followUpAfter = followUpAfter
        self.status = status
    }
}

public struct CallSummary: Codable, Sendable, Hashable, Identifiable {
    public var callId: String
    public var summary: String
    public var durationSec: Int
    public var createdAt: Date
    public var topics: [Topic]

    public var id: String { callId }

    public init(callId: String, summary: String, durationSec: Int, createdAt: Date, topics: [Topic] = []) {
        self.callId = callId
        self.summary = summary
        self.durationSec = durationSec
        self.createdAt = createdAt
        self.topics = topics
    }
}

public struct Memories: Codable, Sendable, Hashable {
    public var topics: [Topic]
    public var summaries: [CallSummary]

    public init(topics: [Topic] = [], summaries: [CallSummary] = []) {
        self.topics = topics
        self.summaries = summaries
    }
}

public struct CallHistoryEntry: Codable, Sendable, Hashable, Identifiable {
    public var callId: String
    public var startedAt: Date
    public var durationSec: Int
    public var id: String { callId }

    public init(callId: String, startedAt: Date, durationSec: Int) {
        self.callId = callId
        self.startedAt = startedAt
        self.durationSec = durationSec
    }
}

public struct CallJoin: Codable, Sendable, Hashable {
    public var callId: String
    public var meeting: JSONValue
    public var attendee: JSONValue
    public var peer: PublicUser
    public var peerNickname: String?
    public var peerAttendeeId: String
    public var memoryAllowed: Bool

    public var peerName: String { peerNickname?.nonEmpty ?? peer.displayName }

    public init(callId: String, meeting: JSONValue, attendee: JSONValue, peer: PublicUser, peerNickname: String?, peerAttendeeId: String, memoryAllowed: Bool) {
        self.callId = callId
        self.meeting = meeting
        self.attendee = attendee
        self.peer = peer
        self.peerNickname = peerNickname
        self.peerAttendeeId = peerAttendeeId
        self.memoryAllowed = memoryAllowed
    }
}

public struct PhotoStatus: Codable, Sendable, Hashable {
    public var indexed: Int
    /// How many of `indexed` are short videos.
    public var videos: Int?
    public var excluded: Int
    public var pending: Int
    public var failed: Int
    public var lastIndexedAt: Date?

    public init(indexed: Int = 0, excluded: Int = 0, pending: Int = 0, failed: Int = 0, lastIndexedAt: Date? = nil) {
        self.indexed = indexed
        self.excluded = excluded
        self.pending = pending
        self.failed = failed
        self.lastIndexedAt = lastIndexedAt
    }
}

public struct AuthTokens: Codable, Sendable, Hashable {
    public var accessToken: String
    public var idToken: String
    public var refreshToken: String?
    public var expiresIn: Int
    public var userId: String
    public var isNew: Bool

    public init(accessToken: String, idToken: String, refreshToken: String?, expiresIn: Int, userId: String, isNew: Bool) {
        self.accessToken = accessToken
        self.idToken = idToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.userId = userId
        self.isNew = isNew
    }
}

public struct BusyBlock: Codable, Sendable, Hashable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public struct AvailabilityUpload: Codable, Sendable, Hashable {
    public var busyBlocks: [BusyBlock]
    public var syncedAt: Date
    public var source: String
    public var tz: String

    public init(busyBlocks: [BusyBlock], syncedAt: Date, source: String = "apple", tz: String) {
        self.busyBlocks = busyBlocks
        self.syncedAt = syncedAt
        self.source = source
        self.tz = tz
    }
}

public struct ContextReport: Codable, Sendable, Hashable {
    public struct Focus: Codable, Sendable, Hashable {
        public var isFocused: Bool
        public var at: Date
        public init(isFocused: Bool, at: Date) { self.isFocused = isFocused; self.at = at }
    }

    public struct Driving: Codable, Sendable, Hashable {
        public var isDriving: Bool
        public var at: Date
        public init(isDriving: Bool, at: Date) { self.isDriving = isDriving; self.at = at }
    }

    public var focus: Focus?
    public var driving: Driving?

    public init(focus: Focus? = nil, driving: Driving? = nil) {
        self.focus = focus
        self.driving = driving
    }
}

public struct DeviceRegistration: Codable, Sendable, Hashable {
    public enum APNsEnvironment: String, Codable, Sendable { case sandbox, production }

    public var deviceId: String
    public var apnsToken: String?
    public var voipToken: String?
    public var apnsEnv: APNsEnvironment
    public var appVersion: String

    public init(deviceId: String, apnsToken: String?, voipToken: String?, apnsEnv: APNsEnvironment, appVersion: String) {
        self.deviceId = deviceId
        self.apnsToken = apnsToken
        self.voipToken = voipToken
        self.apnsEnv = apnsEnv
        self.appVersion = appVersion
    }
}

/// Whether an indexed item is a still photo or a short video (VID-1).
public enum MediaType: String, Codable, Sendable, Hashable {
    case photo, video
}

public struct PhotoUploadItem: Codable, Sendable, Hashable {
    public var assetHash: String
    public var takenAt: Date
    public var place: String?
    public var isScreenshot: Bool
    public var width: Int
    public var height: Int
    public var mediaType: MediaType?
    public var durationMs: Int?

    public init(assetHash: String, takenAt: Date, place: String?, isScreenshot: Bool, width: Int, height: Int,
                mediaType: MediaType? = nil, durationMs: Int? = nil) {
        self.assetHash = assetHash
        self.takenAt = takenAt
        self.place = place
        self.isScreenshot = isScreenshot
        self.width = width
        self.height = height
        self.mediaType = mediaType
        self.durationMs = durationMs
    }
}

public struct PhotoUploadTicket: Codable, Sendable, Hashable {
    public var assetHash: String
    /// The JPEG (a video's poster frame).
    public var uploadUrl: URL
    /// The MP4, for videos only.
    public var videoUploadUrl: URL?
}

public struct PhotoUploadsResponse: Codable, Sendable, Hashable {
    public var uploads: [PhotoUploadTicket]
    public var skipped: [String]
}

public struct PhotoSuggestion: Codable, Sendable, Hashable, Identifiable {
    public var callId: String
    public var suggestionId: String
    public var photoId: String
    public var thumbUrl: URL
    public var query: String
    public var confidence: Double
    public var auto: Bool
    /// Set for a short video: `thumbUrl` is its poster frame and `videoUrl` the clip (5-minute link).
    public var mediaType: MediaType?
    public var durationMs: Int?
    public var videoUrl: URL?

    public var id: String { suggestionId }
    public var isVideo: Bool { mediaType == .video && videoUrl != nil }

    public init(callId: String, suggestionId: String, photoId: String, thumbUrl: URL, query: String, confidence: Double, auto: Bool,
                mediaType: MediaType? = nil, durationMs: Int? = nil, videoUrl: URL? = nil) {
        self.callId = callId
        self.suggestionId = suggestionId
        self.photoId = photoId
        self.thumbUrl = thumbUrl
        self.query = query
        self.confidence = confidence
        self.auto = auto
        self.mediaType = mediaType
        self.durationMs = durationMs
        self.videoUrl = videoUrl
    }
}

public struct ShareCreated: Codable, Sendable, Hashable {
    public var shareId: String
    public var thumbUrl: URL
    public var mediaType: MediaType?
    public var durationMs: Int?
    public var videoUrl: URL?
}

/// A photo either person showed during a call, for the post-call recap. `url` expires after 5 minutes.
public struct CallPhoto: Codable, Sendable, Hashable, Identifiable {
    public var shareId: String
    public var senderId: String
    public var url: URL
    public var createdAt: Date
    /// Set for a short video: `url` is its poster frame and `videoUrl` the clip.
    public var mediaType: MediaType?
    public var videoUrl: URL?

    public var id: String { shareId }
    public var isVideo: Bool { mediaType == .video }

    public init(shareId: String, senderId: String, url: URL, createdAt: Date, mediaType: MediaType? = nil, videoUrl: URL? = nil) {
        self.shareId = shareId
        self.senderId = senderId
        self.url = url
        self.createdAt = createdAt
        self.mediaType = mediaType
        self.videoUrl = videoUrl
    }
}

public struct ShareURL: Codable, Sendable, Hashable {
    /// The still image (a video's poster frame).
    public var url: URL
    public var expiresAt: Date
    public var mediaType: MediaType?
    public var durationMs: Int?
    public var videoUrl: URL?
}

public struct HandleAvailability: Codable, Sendable, Hashable {
    public enum Reason: String, Codable, Sendable { case taken, invalid, reserved }
    public var available: Bool
    public var reason: Reason?

    public init(available: Bool, reason: Reason? = nil) {
        self.available = available
        self.reason = reason
    }
}

public struct TranscribeConfig: Codable, Sendable, Hashable {
    public var identityPoolId: String
    public var region: String
    public var userPoolProviderName: String
}

public struct APIErrorBody: Codable, Sendable, Hashable {
    public struct Inner: Codable, Sendable, Hashable {
        public var code: String
        public var message: String
    }
    public var error: Inner
}

extension String {
    public var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
