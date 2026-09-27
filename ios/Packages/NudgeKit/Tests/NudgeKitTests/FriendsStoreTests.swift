import Foundation
import Testing
@testable import Friends
@testable import Models
@testable import Networking

@Suite("FriendsStore: free/busy stays current")
@MainActor
struct FriendsStoreTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    func store(_ friends: [Friend]) -> FriendsStore {
        let s = FriendsStore(api: NudgeAPI(client: APIClient(baseURL: URL(string: "https://example.invalid")!)))
        s.preview(friends: friends)
        return s
    }

    func friend(_ id: String, freeNow: Bool, freeUntil: Date? = nil, busyUntil: Date? = nil) -> Friend {
        Friend(user: PublicUser(id: id, handle: id, displayName: id), since: Self.at(-10_000),
               freeNow: freeNow, freeUntil: freeUntil, busyUntil: busyUntil)
    }

    @Test func decodesBusyUntil() throws {
        let json = #"""
        {"user":{"id":"u_1","handle":"sunay","displayName":"Sunay"},"since":"2026-09-01T00:00:00Z",
         "freeNow":false,"busyUntil":"2026-09-26T19:00:00Z"}
        """#
        let f = try NudgeJSON.decoder().decode(Friend.self, from: Data(json.utf8))
        #expect(f.busyUntil != nil)
        #expect(f.statusChangesAt == f.busyUntil)
    }

    @Test func lapsedFreeWindowIsDropped() {
        let s = store([friend("alan", freeNow: true, freeUntil: Self.at(-1)), friend("sam", freeNow: true, freeUntil: Self.at(30))])
        s.expireLapsed(now: Self.now)
        #expect(s.friend(id: "alan")?.freeNow == false)
        #expect(s.friend(id: "alan")?.freeUntil == nil)
        #expect(s.friend(id: "sam")?.freeNow == true)
        #expect(s.freeNow.map(\.id) == ["sam"])
    }

    @Test func refetchesWhenAStatusBoundaryPasses() {
        let s = store([friend("alan", freeNow: true, freeUntil: Self.at(10)), friend("sunay", freeNow: false, busyUntil: Self.at(20))])
        s.lastLoadedAt = Self.now
        #expect(!s.needsRefresh(now: Self.at(2)))
        #expect(s.needsRefresh(now: Self.at(10))) // Alan's window closed
    }

    @Test func busyEndingTriggersRefetch() {
        let s = store([friend("sunay", freeNow: false, busyUntil: Self.at(3))])
        s.lastLoadedAt = Self.now
        #expect(!s.needsRefresh(now: Self.at(2)))
        #expect(s.needsRefresh(now: Self.at(3))) // Sunay may be free now
    }

    @Test func refetchesAfterTheIntervalEvenWithNoBoundary() {
        let s = store([friend("mom", freeNow: true)])
        s.lastLoadedAt = Self.now
        #expect(!s.needsRefresh(now: Self.at(4)))
        #expect(s.needsRefresh(now: Self.at(5)))
    }
}
