import Foundation
import Testing
@testable import Models
@testable import Networking
@testable import Nudges

@Suite("NudgeCenter — NUD-9 in-app banner")
@MainActor
struct NudgeCenterTests {
    static func nudge(id: String = "n_1", state: String, myResponse: String? = nil) throws -> Nudge {
        let mine = myResponse.map { #","myResponse":"\#($0)""# } ?? ""
        let json = #"""
        {"id":"\#(id)","kind":"direct","friend":{"id":"u_2","handle":"bot","displayName":"Test Bot"},
         "state":"\#(state)"\#(mine),"window":{"start":"2026-09-26T15:00:00Z","end":"2026-09-26T15:10:00Z"},
         "minutes":10,"title":"Test Bot wants to call","body":"Test Bot wants to call. Free?"}
        """#
        return try NudgeJSON.decoder().decode(Nudge.self, from: Data(json.utf8))
    }

    func center() -> NudgeCenter {
        NudgeCenter(api: NudgeAPI(client: APIClient(baseURL: URL(string: "https://example.invalid")!)), socket: nil)
    }

    @Test func websocketNudgeShowsBannerWithoutWaitingForPush() throws {
        let c = center()
        c.apply(.nudgeUpdated(try Self.nudge(state: "accepted_by_one")))
        #expect(c.banner?.id == "n_1")
    }

    @Test func answeredOrFinishedNudgesDoNotShowBanner() throws {
        let c = center()
        c.apply(.nudgeUpdated(try Self.nudge(state: "accepted_by_one", myResponse: "accepted")))
        c.apply(.nudgeUpdated(try Self.nudge(id: "n_2", state: "expired")))
        #expect(c.banner == nil)
    }

    @Test func terminalUpdateClearsBanner() throws {
        let c = center()
        c.apply(.nudgeUpdated(try Self.nudge(state: "pending")))
        c.apply(.nudgeUpdated(try Self.nudge(state: "skipped")))
        #expect(c.banner == nil)
    }
}
