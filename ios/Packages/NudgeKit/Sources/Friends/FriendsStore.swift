import Contacts
import Foundation
import Models
import Networking
import Observation

@MainActor
@Observable
public final class FriendsStore {
    public private(set) var friends: [Friend] = []
    public private(set) var requests = FriendRequests()
    public private(set) var searchResults: [SearchResult] = []
    public private(set) var contactMatches: [SearchResult] = []
    public private(set) var blocked: [PublicUser] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public var error: String?

    private let api: NudgeAPI
    private let hasher = PhoneHasher()
    private var searchTask: Task<Void, Never>?

    public init(api: NudgeAPI) { self.api = api }

    public var freeNow: [Friend] { friends.filter(\.freeNow).sorted { $0.name < $1.name } }
    public var sortedFriends: [Friend] { friends.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }

    public func friend(id: String) -> Friend? { friends.first { $0.id == id } }

    public func load() async {
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        do {
            async let f = api.friends()
            async let r = api.friendRequests()
            friends = try await f
            requests = try await r
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func search(_ query: String) {
        searchTask?.cancel()
        let q = HandleRule.normalize(query)
        guard q.count >= 2 else { searchResults = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do { searchResults = try await api.searchUsers(q) } catch { self.error = error.localizedDescription }
        }
    }

    public func add(userId: String) async {
        do {
            let relation = try await api.sendFriendRequest(userId: userId)
            update(userId: userId, relation: relation)
            if relation == .friends { await load() }
        } catch { self.error = error.localizedDescription }
    }

    public func add(handle: String) async -> Relation? {
        do {
            let relation = try await api.sendFriendRequest(handle: HandleRule.normalize(handle))
            await load()
            return relation
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func update(userId: String, relation: Relation) {
        if let i = searchResults.firstIndex(where: { $0.id == userId }) { searchResults[i].relation = relation }
        if let i = contactMatches.firstIndex(where: { $0.id == userId }) { contactMatches[i].relation = relation }
    }

    public func accept(_ userId: String) async {
        do { _ = try await api.acceptRequest(from: userId); await load() } catch { self.error = error.localizedDescription }
    }

    public func decline(_ userId: String) async {
        do { try await api.declineRequest(from: userId); await load() } catch { self.error = error.localizedDescription }
    }

    public func cancel(_ userId: String) async {
        do { try await api.cancelRequest(to: userId); await load() } catch { self.error = error.localizedDescription }
    }

    public func setNickname(_ nickname: String?, for userId: String) async {
        do {
            let updated = try await api.setNickname(nickname?.nonEmpty, for: userId)
            if let i = friends.firstIndex(where: { $0.id == userId }) { friends[i] = updated }
        } catch { self.error = error.localizedDescription }
    }

    public func remove(_ userId: String) async {
        do { try await api.removeFriend(userId); friends.removeAll { $0.id == userId } } catch { self.error = error.localizedDescription }
    }

    public func block(_ userId: String) async {
        do { try await api.block(userId); friends.removeAll { $0.id == userId }; await loadBlocked() } catch { self.error = error.localizedDescription }
    }

    public func unblock(_ userId: String) async {
        do { try await api.unblock(userId); blocked.removeAll { $0.id == userId } } catch { self.error = error.localizedDescription }
    }

    public func loadBlocked() async {
        do { blocked = try await api.blocked() } catch { self.error = error.localizedDescription }
    }

    /// Reads contacts, hashes numbers on device, and asks the server which ones use Nudge (ACC-7).
    public func matchContacts() async {
        let numbers = await Task.detached(priority: .userInitiated) { () -> [String] in
            let store = CNContactStore()
            let request = CNContactFetchRequest(keysToFetch: [CNContactPhoneNumbersKey as CNKeyDescriptor])
            var numbers: [String] = []
            try? store.enumerateContacts(with: request) { contact, _ in
                numbers += contact.phoneNumbers.map { $0.value.stringValue }
            }
            return numbers
        }.value
        let hashes = hasher.hashes(for: numbers)
        guard !hashes.isEmpty else { contactMatches = []; return }
        do { contactMatches = try await api.matchContacts(hashes: hashes) } catch { self.error = error.localizedDescription }
    }

    public static var contactsAuthorized: Bool {
        let s = CNContactStore.authorizationStatus(for: .contacts)
        return s == .authorized || s == .limited
    }

    // MARK: Preview / screenshot support

    public func preview(friends: [Friend], requests: FriendRequests = FriendRequests(), search: [SearchResult] = [], contacts: [SearchResult] = [], blocked: [PublicUser] = []) {
        self.friends = friends
        self.requests = requests
        self.searchResults = search
        self.contactMatches = contacts
        self.blocked = blocked
        self.hasLoaded = true
    }

    /// Applies server push events.
    public func apply(_ event: ServerEvent) async {
        switch event {
        case .friendRequest, .friendAccepted: await load()
        default: break
        }
    }
}
