import Foundation
import Models
import Networking
import Observation

@MainActor
@Observable
public final class MemoryStore {
    public private(set) var byFriend: [String: Memories] = [:]
    public private(set) var callHistory: [String: [CallHistoryEntry]] = [:]
    /// Summary screen after a call (MEM-6).
    public private(set) var pendingSummary: PendingSummary?
    public var error: String?
    private let api: NudgeAPI
    private var pollTask: Task<Void, Never>?
    private var photosTask: Task<Void, Never>?

    public struct PendingSummary: Identifiable, Hashable, Sendable {
        public var id: String { callId }
        public var callId: String
        public var friendId: String
        public var friendName: String
        public var durationSec: Int
        public var summary: CallSummary?
        public var memoryAllowed: Bool
        /// Photos either person showed during the call.
        public var photos: [CallPhoto]
        /// Polling gave up before the summary was written; it will still land on the friend's profile.
        public var summaryTimedOut: Bool

        /// Nothing more is coming, so the screen may start its auto-close countdown.
        public var isSettled: Bool { summary != nil || !memoryAllowed || summaryTimedOut }

        public init(callId: String, friendId: String, friendName: String, durationSec: Int, summary: CallSummary? = nil,
                    memoryAllowed: Bool = true, photos: [CallPhoto] = [], summaryTimedOut: Bool = false) {
            self.callId = callId
            self.friendId = friendId
            self.friendName = friendName
            self.durationSec = durationSec
            self.summary = summary
            self.memoryAllowed = memoryAllowed
            self.photos = photos
            self.summaryTimedOut = summaryTimedOut
        }
    }

    public init(api: NudgeAPI) { self.api = api }

    public func load(friendId: String) async {
        do {
            async let m = api.memories(friendId: friendId)
            async let h = api.callHistory(friendId: friendId)
            byFriend[friendId] = try await m
            callHistory[friendId] = try await h
        } catch { self.error = error.localizedDescription }
    }

    public func deleteTopic(_ topic: Topic, friendId: String) async {
        byFriend[friendId]?.topics.removeAll { $0.id == topic.id }
        if var p = pendingSummary, p.friendId == friendId { p.summary?.topics.removeAll { $0.id == topic.id }; pendingSummary = p }
        do { try await api.deleteTopic(friendId: friendId, topicId: topic.id) } catch { self.error = error.localizedDescription }
    }

    public func deleteSummary(_ callId: String, friendId: String) async {
        byFriend[friendId]?.summaries.removeAll { $0.callId == callId }
        do { try await api.deleteSummary(friendId: friendId, callId: callId) } catch { self.error = error.localizedDescription }
    }

    public func deleteAll() async {
        byFriend = [:]
        do { try await api.deleteAllMemories() } catch { self.error = error.localizedDescription }
    }

    /// Shows the summary screen immediately, loads the call's photos, and polls until topics are ready (≤ 60 s).
    public func callEnded(callId: String, friendId: String, friendName: String, durationSec: Int, memoryAllowed: Bool) {
        pendingSummary = PendingSummary(callId: callId, friendId: friendId, friendName: friendName, durationSec: durationSec, memoryAllowed: memoryAllowed)
        pollTask?.cancel()
        photosTask?.cancel()
        photosTask = Task {
            // The server may not have recorded the end yet when the other side hung up (409 call_active).
            for attempt in 0..<4 {
                if Task.isCancelled { return }
                if let photos = try? await api.callPhotos(callId: callId) {
                    if pendingSummary?.callId == callId { pendingSummary?.photos = photos }
                    return
                }
                try? await Task.sleep(for: .seconds(1 + attempt))
            }
        }
        guard memoryAllowed else { return }
        pollTask = Task {
            for _ in 0..<20 {
                if Task.isCancelled { return }
                if let s = try? await api.summary(callId: callId) {
                    if pendingSummary?.callId == callId { pendingSummary?.summary = s }
                    return
                }
                try? await Task.sleep(for: .seconds(3))
            }
            if !Task.isCancelled, pendingSummary?.callId == callId { pendingSummary?.summaryTimedOut = true }
        }
    }

    public func summaryReady(callId: String) async {
        guard pendingSummary?.callId == callId, let s = try? await api.summary(callId: callId) else { return }
        pendingSummary?.summary = s
    }

    /// Fetches new links for the summary's photos (they expire after 5 minutes), for export.
    public func refreshPhotos(callId: String) async -> [CallPhoto]? {
        guard let photos = try? await api.callPhotos(callId: callId) else { return nil }
        if pendingSummary?.callId == callId { pendingSummary?.photos = photos }
        return photos
    }

    public func dismissSummary() {
        pollTask?.cancel()
        photosTask?.cancel()
        pendingSummary = nil
    }

    public func preview(friendId: String, memories: Memories, history: [CallHistoryEntry] = [], pending: PendingSummary? = nil) {
        byFriend[friendId] = memories
        callHistory[friendId] = history
        pendingSummary = pending
    }
}
