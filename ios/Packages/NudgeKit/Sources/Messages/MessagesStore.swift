import Foundation
import Models
import Networking
import Observation

@MainActor
@Observable
public final class MessagesStore {
    public private(set) var conversations: [Conversation] = []
    /// Newest last, for display.
    public private(set) var threads: [String: [Message]] = [:]
    public private(set) var hasLoaded = false
    public var error: String?
    private let api: NudgeAPI

    public init(api: NudgeAPI) { self.api = api }

    public var unreadTotal: Int { conversations.reduce(0) { $0 + $1.unread } }

    public func loadConversations() async {
        defer { hasLoaded = true }
        do {
            conversations = try await api.conversations().sorted {
                ($0.lastMessage?.createdAt ?? .distantPast) > ($1.lastMessage?.createdAt ?? .distantPast)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    public func loadThread(friendId: String) async {
        do {
            threads[friendId] = try await api.messages(friendId: friendId).sorted { $0.createdAt < $1.createdAt }
            try? await api.markRead(friendId: friendId)
            if let i = conversations.firstIndex(where: { $0.id == friendId }) { conversations[i].unread = 0 }
        } catch { self.error = error.localizedDescription }
    }

    public func send(_ body: String, to friendId: String) async {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            let m = try await api.sendMessage(friendId: friendId, body: String(text.prefix(1000)))
            append(m, friendId: friendId)
        } catch { self.error = error.localizedDescription }
    }

    public func apply(_ event: ServerEvent, openThread: String?) {
        guard case .messageNew(let friendId, let message) = event else { return }
        append(message, friendId: friendId)
        if let i = conversations.firstIndex(where: { $0.id == friendId }) {
            conversations[i].lastMessage = message
            if openThread != friendId { conversations[i].unread += 1 }
            let c = conversations.remove(at: i)
            conversations.insert(c, at: 0)
        } else {
            Task { await loadConversations() }
        }
    }

    private func append(_ m: Message, friendId: String) {
        var t = threads[friendId] ?? []
        guard !t.contains(where: { $0.id == m.id }) else { return }
        t.append(m)
        threads[friendId] = t
    }

    public func preview(conversations: [Conversation], threads: [String: [Message]]) {
        self.conversations = conversations
        self.threads = threads
        hasLoaded = true
    }
}
