import Foundation
import Models

/// Typed wrappers for every REST endpoint in SPEC §3.7.
public struct NudgeAPI: Sendable {
    public let client: APIClient

    public init(client: APIClient) { self.client = client }

    // MARK: Auth (no bearer)

    struct AppleBody: Encodable, Sendable { let identityToken: String; let fullName: String? }
    struct RefreshBody: Encodable, Sendable { let refreshToken: String; let userId: String }
    struct DevBody: Encodable, Sendable { let username: String }

    public func signInWithApple(identityToken: String, fullName: String?) async throws -> AuthTokens {
        try await client.request(.post, "/auth/apple", body: AppleBody(identityToken: identityToken, fullName: fullName), authenticated: false)
    }

    public func refresh(refreshToken: String, userId: String) async throws -> AuthTokens {
        try await client.request(.post, "/auth/refresh", body: RefreshBody(refreshToken: refreshToken, userId: userId), authenticated: false)
    }

    public func devSignIn(username: String) async throws -> AuthTokens {
        try await client.request(.post, "/auth/dev", body: DevBody(username: username), authenticated: false)
    }

    // MARK: Me

    public func me() async throws -> MeResponse { try await client.request(.get, "/me") }

    public func updateMe(_ patch: MePatch) async throws -> MeResponse {
        try await client.request(.patch, "/me", body: patch)
    }

    struct VersionBody: Encodable, Sendable { let version: String }
    public func acceptTos(version: String) async throws -> MeResponse {
        try await client.request(.post, "/me/tos", body: VersionBody(version: version))
    }

    public func handleAvailability(_ handle: String) async throws -> HandleAvailability {
        try await client.request(.get, "/handles/\(handle.urlPathEscaped)")
    }

    struct HandleBody: Encodable, Sendable { let handle: String }
    public func claimHandle(_ handle: String) async throws -> MeResponse {
        try await client.request(.put, "/me/handle", body: HandleBody(handle: handle))
    }

    public struct AvatarUpload: Decodable, Sendable { public let uploadUrl: URL; public let avatarKey: String }
    public func avatarUploadURL() async throws -> AvatarUpload { try await client.request(.post, "/me/avatar") }

    struct PhoneBody: Encodable, Sendable { let phone: String }
    struct CodeSent: Decodable, Sendable { let codeSent: Bool }
    public func startPhoneVerification(e164: String) async throws {
        let _: CodeSent = try await client.request(.post, "/me/phone", body: PhoneBody(phone: e164))
    }

    struct CodeBody: Encodable, Sendable { let code: String }
    public func verifyPhone(code: String) async throws -> MeResponse {
        try await client.request(.post, "/me/phone/verify", body: CodeBody(code: code))
    }

    public func removePhone() async throws -> MeResponse { try await client.request(.delete, "/me/phone") }

    public func registerDevice(_ registration: DeviceRegistration) async throws {
        try await client.send(.post, "/me/devices", body: registration)
    }

    public func uploadAvailability(_ upload: AvailabilityUpload) async throws {
        try await client.send(.put, "/me/availability", body: upload)
    }

    public func reportContext(_ report: ContextReport) async throws {
        try await client.send(.put, "/me/context", body: report)
    }

    public func frequencyLess() async throws -> MeResponse { try await client.request(.post, "/me/frequency/less") }
    public func frequencyUndo() async throws -> MeResponse { try await client.request(.post, "/me/frequency/undo") }
    public func deleteAccount() async throws { try await client.send(.delete, "/me") }

    // MARK: Friends

    struct Results: Decodable, Sendable { let results: [SearchResult] }
    public func searchUsers(_ q: String) async throws -> [SearchResult] {
        let r: Results = try await client.request(.get, "/users/search", query: [URLQueryItem(name: "q", value: q)])
        return r.results
    }

    struct HashesBody: Encodable, Sendable { let hashes: [String] }
    public func matchContacts(hashes: [String]) async throws -> [SearchResult] {
        var all: [SearchResult] = []
        for chunk in hashes.chunked(2000) {
            let r: Results = try await client.request(.post, "/contacts/match", body: HashesBody(hashes: chunk))
            all += r.results
        }
        return all
    }

    struct FriendsBody: Decodable, Sendable { let friends: [Friend] }
    public func friends() async throws -> [Friend] {
        let r: FriendsBody = try await client.request(.get, "/friends")
        return r.friends
    }

    public func friendRequests() async throws -> FriendRequests { try await client.request(.get, "/friend-requests") }

    struct RequestBody: Encodable, Sendable { let userId: String?; let handle: String? }
    struct RelationBody: Decodable, Sendable { let relation: Relation }
    public func sendFriendRequest(userId: String? = nil, handle: String? = nil) async throws -> Relation {
        let r: RelationBody = try await client.request(.post, "/friend-requests", body: RequestBody(userId: userId, handle: handle))
        return r.relation
    }

    public func acceptRequest(from userId: String) async throws -> Relation {
        let r: RelationBody = try await client.request(.post, "/friend-requests/\(userId)/accept")
        return r.relation
    }

    public func declineRequest(from userId: String) async throws { try await client.send(.post, "/friend-requests/\(userId)/decline") }
    public func cancelRequest(to userId: String) async throws { try await client.send(.delete, "/friend-requests/\(userId)") }

    struct NicknameBody: Encodable, Sendable {
        let nickname: String?
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            try c.encode(nickname, forKey: .nickname) // explicit null clears
        }
        enum K: String, CodingKey { case nickname }
    }
    public func setNickname(_ nickname: String?, for userId: String) async throws -> Friend {
        try await client.request(.patch, "/friends/\(userId)", body: NicknameBody(nickname: nickname))
    }

    public func removeFriend(_ userId: String) async throws { try await client.send(.delete, "/friends/\(userId)") }

    struct UsersBody: Decodable, Sendable { let users: [PublicUser] }
    public func blocked() async throws -> [PublicUser] {
        let r: UsersBody = try await client.request(.get, "/blocks")
        return r.users
    }
    public func block(_ userId: String) async throws { try await client.send(.post, "/blocks/\(userId)") }
    public func unblock(_ userId: String) async throws { try await client.send(.delete, "/blocks/\(userId)") }

    public func memories(friendId: String) async throws -> Memories { try await client.request(.get, "/friends/\(friendId)/memories") }
    public func deleteTopic(friendId: String, topicId: String) async throws { try await client.send(.delete, "/friends/\(friendId)/topics/\(topicId)") }
    public func dismissTopic(friendId: String, topicId: String) async throws { try await client.send(.post, "/friends/\(friendId)/topics/\(topicId)/dismiss") }
    public func deleteSummary(friendId: String, callId: String) async throws { try await client.send(.delete, "/friends/\(friendId)/summaries/\(callId)") }
    public func deleteAllMemories() async throws { try await client.send(.delete, "/memories") }

    struct CallsBody: Decodable, Sendable { let calls: [CallHistoryEntry] }
    public func callHistory(friendId: String) async throws -> [CallHistoryEntry] {
        let r: CallsBody = try await client.request(.get, "/friends/\(friendId)/calls")
        return r.calls
    }

    public func callNow(friendId: String) async throws -> Nudge { try await client.request(.post, "/friends/\(friendId)/call") }

    // MARK: Messages

    struct ConversationsBody: Decodable, Sendable { let conversations: [Conversation] }
    public func conversations() async throws -> [Conversation] {
        let r: ConversationsBody = try await client.request(.get, "/conversations")
        return r.conversations
    }

    struct MessagesBody: Decodable, Sendable { let messages: [Message] }
    public func messages(friendId: String, before: Date? = nil) async throws -> [Message] {
        let q = before.map { [URLQueryItem(name: "before", value: NudgeJSON.formatDate($0))] } ?? []
        let r: MessagesBody = try await client.request(.get, "/friends/\(friendId)/messages", query: q)
        return r.messages
    }

    struct BodyText: Encodable, Sendable { let body: String }
    public func sendMessage(friendId: String, body: String) async throws -> Message {
        try await client.request(.post, "/friends/\(friendId)/messages", body: BodyText(body: body))
    }

    public func markRead(friendId: String) async throws { try await client.send(.post, "/friends/\(friendId)/messages/read") }

    // MARK: Nudges & calls

    struct ActiveBody: Decodable, Sendable { let nudge: Nudge? }
    public func activeNudge() async throws -> Nudge? {
        let r: ActiveBody = try await client.request(.get, "/nudges/active")
        return r.nudge
    }

    public func nudge(_ id: String) async throws -> Nudge { try await client.request(.get, "/nudges/\(id)") }

    struct ActionBody: Encodable, Sendable { let action: NudgeAction }
    public func respond(nudgeId: String, action: NudgeAction) async throws -> Nudge {
        try await client.request(.post, "/nudges/\(nudgeId)/respond", body: ActionBody(action: action))
    }

    public func cancelNudge(_ id: String) async throws -> Nudge { try await client.request(.post, "/nudges/\(id)/cancel") }

    struct FollowUpBody: Encodable, Sendable { let action: String; let body: String? }
    /// Sends my drafted follow-up (optionally edited) or discards it (NUD-12).
    public func resolveFollowUp(nudgeId: String, send: Bool, body: String? = nil) async throws -> Nudge {
        try await client.request(.post, "/nudges/\(nudgeId)/followup", body: FollowUpBody(action: send ? "send" : "discard", body: body))
    }

    public func join(callId: String) async throws -> CallJoin { try await client.request(.get, "/calls/\(callId)/join") }
    public func endCall(_ callId: String) async throws { try await client.send(.post, "/calls/\(callId)/end") }

    /// Returns nil while the summary is still being written (HTTP 202).
    public func summary(callId: String) async throws -> CallSummary? {
        struct MaybeSummary: Decodable, Sendable {
            let pending: Bool?
            let summary: CallSummary?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: K.self)
                pending = try c.decodeIfPresent(Bool.self, forKey: .pending)
                summary = pending == true ? nil : try CallSummary(from: decoder)
            }
            enum K: String, CodingKey { case pending }
        }
        let r: MaybeSummary = try await client.request(.get, "/calls/\(callId)/summary")
        return r.summary
    }

    struct ShareBody: Encodable, Sendable { let photoId: String; let suggestionId: String? }
    public func createShare(callId: String, photoId: String, suggestionId: String?) async throws -> ShareCreated {
        try await client.request(.post, "/calls/\(callId)/shares", body: ShareBody(photoId: photoId, suggestionId: suggestionId))
    }

    private struct SuggestionFeedbackBody: Encodable, Sendable { let outcome: String }
    public func dismissSuggestion(callId: String, suggestionId: String) async throws {
        try await client.send(.post, "/calls/\(callId)/suggestions/\(suggestionId)/feedback", body: SuggestionFeedbackBody(outcome: "dismissed"))
    }

    public func shareURL(callId: String, shareId: String) async throws -> ShareURL {
        try await client.request(.get, "/calls/\(callId)/shares/\(shareId)")
    }

    struct ShownBody: Encodable, Sendable { let shownAt: Date; let durationMs: Int }
    public func markShown(callId: String, shareId: String, shownAt: Date, durationMs: Int) async throws {
        try await client.send(.post, "/calls/\(callId)/shares/\(shareId)/shown", body: ShownBody(shownAt: shownAt, durationMs: durationMs))
    }

    // MARK: Photos & transcription

    struct UploadsBody: Encodable, Sendable { let items: [PhotoUploadItem] }
    public func photoUploads(_ items: [PhotoUploadItem]) async throws -> PhotoUploadsResponse {
        try await client.request(.post, "/photos/uploads", body: UploadsBody(items: items))
    }

    public func photoStatus() async throws -> PhotoStatus { try await client.request(.get, "/photos/status") }
    public func deletePhoto(assetHash: String) async throws { try await client.send(.delete, "/photos/\(assetHash)") }
    public func deleteAllPhotos() async throws { try await client.send(.delete, "/photos") }
    public func transcribeConfig() async throws -> TranscribeConfig { try await client.request(.get, "/transcribe/config") }

    public struct TelemetryEvent: Encodable, Sendable {
        public let name: String
        public let ms: Double
        public let callId: String?
        public init(name: String, ms: Double, callId: String?) { self.name = name; self.ms = ms; self.callId = callId }
    }
    struct TelemetryBody: Encodable, Sendable { let events: [TelemetryEvent] }
    public func telemetry(_ events: [TelemetryEvent]) async throws {
        try await client.send(.post, "/telemetry", body: TelemetryBody(events: events))
    }
}

extension String {
    var urlPathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
