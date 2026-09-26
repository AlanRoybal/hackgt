import Foundation
import Testing
@testable import PhotoShare

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
private func photo(_ id: String) -> OutgoingPhoto { OutgoingPhoto(photoId: id, suggestionId: "sg-\(id)", image: .placeholder(id)) }
private func ref(_ id: String, sender: String) -> PhotoRef {
    PhotoRef(shareId: id, senderId: sender, image: .placeholder(id), startedAt: t0, durationMs: 6000)
}

@Suite("DisplayRule — REF-8 truth table")
struct DisplayRuleTests {
    @Test func neitherSharing() { #expect(DisplayRule.resolve(mine: nil, other: nil) == .selfView) }
    @Test func onlyMine() {
        let m = ref("a", sender: "me")
        #expect(DisplayRule.resolve(mine: m, other: nil) == .mine(m))
    }
    @Test func onlyOther() {
        let o = ref("b", sender: "them")
        #expect(DisplayRule.resolve(mine: nil, other: o) == .other(o))
    }
    @Test func bothSharingShowsOther() {
        let m = ref("a", sender: "me"), o = ref("b", sender: "them")
        #expect(DisplayRule.resolve(mine: m, other: o) == .other(o))
    }

    /// Two devices applying the same rule: if only A shares, both windows show A's photo;
    /// if both share, each shows the other's.
    @Test func twoDeviceScenarios() {
        let a = ref("pa", sender: "A"), b = ref("pb", sender: "B")
        // Only A shares
        #expect(DisplayRule.resolve(mine: a, other: nil).photo == a)   // A's device
        #expect(DisplayRule.resolve(mine: nil, other: a).photo == a)   // B's device
        // Both share
        #expect(DisplayRule.resolve(mine: a, other: b).photo == b)     // A sees B's
        #expect(DisplayRule.resolve(mine: b, other: a).photo == a)     // B sees A's
        // A's ends → both fall back to B's
        #expect(DisplayRule.resolve(mine: nil, other: b).photo == b)
        #expect(DisplayRule.resolve(mine: b, other: nil).photo == b)
    }
}

@Suite("PhotoTiming — REF-9")
struct PhotoTimingTests {
    @Test(arguments: [(1, 6000), (2, 4500), (3, 3500), (4, 3500), (5, 3500), (0, 6000)])
    func durations(n: Int, ms: Int) { #expect(PhotoTiming.durationMs(pendingIncludingCurrent: n) == ms) }
}

@Suite("PhotoShareMessage codec — §3.10")
struct MessageCodecTests {
    @Test func roundTrip() throws {
        let m = PhotoShareMessage(type: .offer, seq: 7, shareId: "s_123", senderId: "u_1", durationMs: 6000, queueIndex: 0, queueLength: 1)
        let data = try m.encoded()
        #expect(data.count <= 2048)
        #expect(try PhotoShareMessage.decode(data) == m)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"type\":\"offer\""))
        #expect(json.contains("\"v\":1"))
    }

    @Test func rejectsOversize() {
        let m = PhotoShareMessage(type: .offer, seq: 1, shareId: String(repeating: "x", count: 3000), senderId: "u")
        #expect(throws: PhotoShareMessage.CodecError.self) { try m.encoded() }
    }

    @Test func decodesPeerBotShape() throws {
        let json = #"{"v":1,"type":"ready","seq":3,"shareId":"s_9","senderId":"u_2"}"#
        let m = try PhotoShareMessage.decode(Data(json.utf8))
        #expect(m.type == .ready && m.seq == 3 && m.durationMs == nil)
    }

    @Test func ordering() {
        let a = ReceivedPhotoMessage(message: .init(type: .end, seq: 1, shareId: "s", senderId: "b"), timestampMs: 10)
        let b = ReceivedPhotoMessage(message: .init(type: .offer, seq: 2, shareId: "t", senderId: "a"), timestampMs: 10)
        let c = ReceivedPhotoMessage(message: .init(type: .ready, seq: 1, shareId: "s", senderId: "a"), timestampMs: 5)
        #expect(ReceivedPhotoMessage.ordered([a, b, c]).map(\.timestampMs) == [5, 10, 10])
        #expect(ReceivedPhotoMessage.ordered([a, b, c])[1].message.senderId == "a")
    }
}

@Suite("PhotoShareSession — REF-7/9 state machine")
struct SessionTests {
    func sends(_ effects: [PhotoShareSession.Effect]) -> [PhotoShareMessage] {
        effects.compactMap { if case .send(let m) = $0 { m } else { nil } }
    }

    @Test func offerReadyShowEnd() {
        var s = PhotoShareSession(selfId: "me")
        var fx = s.handle(.share(photo("p1")), now: at(0))
        #expect(fx == [.createShare(photo("p1"))])
        fx = s.handle(.shareCreated(photoId: "p1", shareId: "s1"), now: at(0.1))
        let offer = sends(fx).first!
        #expect(offer.type == .offer && offer.durationMs == 6000 && offer.queueLength == 1)
        #expect(s.display(now: at(0.1)) == .selfView) // not shown until ready

        _ = s.handle(.received(.init(message: .init(type: .ready, seq: offer.seq, shareId: "s1", senderId: "them"), timestampMs: 1)), now: at(0.4))
        guard case .mine(let p) = s.display(now: at(0.4)) else { Issue.record("expected mine"); return }
        #expect(p.startedAt == at(0.4) && p.durationMs == 6000)
        #expect(s.nextDeadline == at(6.4))

        fx = s.handle(.tick, now: at(6.4))
        #expect(sends(fx).map(\.type) == [.end])
        #expect(fx.contains(.markShown(shareId: "s1", shownAt: at(0.4), durationMs: 6000)))
        #expect(s.display(now: at(6.4)) == .selfView)
    }

    @Test func readyTimeoutFallsBackAfter1500ms() {
        var s = PhotoShareSession(selfId: "me")
        _ = s.handle(.share(photo("p1")), now: at(0))
        _ = s.handle(.shareCreated(photoId: "p1", shareId: "s1"), now: at(0))
        #expect(s.nextDeadline == at(1.5))
        _ = s.handle(.tick, now: at(1.4))
        #expect(s.mineRef == nil)
        _ = s.handle(.tick, now: at(1.5))
        #expect(s.mineRef?.startedAt == at(1.5))
    }

    /// Coordinator note: two quick taps must not produce two concurrent offers.
    @Test func inFlightCreateGuard() {
        var s = PhotoShareSession(selfId: "me")
        let fx1 = s.handle(.share(photo("p1")), now: at(0))
        let fx2 = s.handle(.share(photo("p2")), now: at(0.05))
        #expect(fx1 == [.createShare(photo("p1"))])
        #expect(fx2.isEmpty)
        #expect(s.creating?.id == "p1" && s.pending.map(\.id) == ["p2"])
        #expect(s.outgoingCount == 2)
    }

    /// Bot semantics: durationMs fixed at offer time from pending-incl-current → 6000, 4500, 6000 for a 3-tap burst
    /// where taps 2 and 3 land while photo 1 is on screen.
    @Test func burstDurationsMatchPeerBot() {
        var s = PhotoShareSession(selfId: "me")
        var durations: [Int] = []
        func created(_ pid: String, _ sid: String, _ t: Double) {
            let fx = s.handle(.shareCreated(photoId: pid, shareId: sid), now: at(t))
            if let d = sends(fx).first?.durationMs { durations.append(d) }
        }
        _ = s.handle(.share(photo("p1")), now: at(0))
        created("p1", "s1", 0)
        _ = s.handle(.tick, now: at(1.5)) // shown
        _ = s.handle(.share(photo("p2")), now: at(2))
        _ = s.handle(.share(photo("p3")), now: at(2.1))
        let fx = s.handle(.tick, now: at(7.5)) // p1 ends → create p2
        #expect(fx.contains(.createShare(photo("p2"))))
        created("p2", "s2", 7.6)
        _ = s.handle(.tick, now: at(9.1))
        _ = s.handle(.tick, now: at(9.1 + 4.5)) // p2 ends → create p3
        created("p3", "s3", 13.7)
        #expect(durations == [6000, 4500, 6000])
    }

    @Test func queueDropsOldestPendingAtFive() {
        var s = PhotoShareSession(selfId: "me")
        for i in 1...7 { _ = s.handle(.share(photo("p\(i)")), now: at(Double(i) * 0.01)) }
        #expect(s.outgoingCount == 5)
        #expect(s.creating?.id == "p1")
        #expect(s.pending.map(\.id) == ["p4", "p5", "p6", "p7"])
    }

    @Test func createFailurePumpsNext() {
        var s = PhotoShareSession(selfId: "me")
        _ = s.handle(.share(photo("p1")), now: at(0))
        _ = s.handle(.share(photo("p2")), now: at(0))
        let fx = s.handle(.shareFailed(photoId: "p1"), now: at(0.2))
        #expect(fx.contains(.createShare(photo("p2"))))
    }

    @Test func recipientFlow() {
        var s = PhotoShareSession(selfId: "me")
        let offer = PhotoShareMessage(type: .offer, seq: 4, shareId: "s9", senderId: "them", durationMs: 4500, queueIndex: 1, queueLength: 3)
        var fx = s.handle(.received(.init(message: offer, timestampMs: 100)), now: at(0))
        #expect(fx == [.fetch(shareId: "s9", senderId: "them")])
        fx = s.handle(.incomingLoaded(shareId: "s9", image: .placeholder("x")), now: at(0.3))
        #expect(sends(fx) == [PhotoShareMessage(type: .ready, seq: 4, shareId: "s9", senderId: "me")])
        guard case .other(let p) = s.display(now: at(0.3)) else { Issue.record("expected other"); return }
        #expect(p.queueIndex == 1 && p.queueLength == 3 && p.durationMs == 4500)
        _ = s.handle(.tick, now: at(4.8))
        #expect(s.display(now: at(4.8)) == .selfView)
    }

    @Test func cancelFromSenderClearsRecipient() {
        var s = PhotoShareSession(selfId: "me")
        _ = s.handle(.received(.init(message: .init(type: .offer, seq: 1, shareId: "s1", senderId: "them", durationMs: 6000), timestampMs: 1)), now: at(0))
        _ = s.handle(.incomingLoaded(shareId: "s1", image: .placeholder("x")), now: at(0.2))
        _ = s.handle(.received(.init(message: .init(type: .cancel, seq: 1, shareId: "s1", senderId: "them"), timestampMs: 2)), now: at(1))
        #expect(s.otherRef == nil)
    }

    @Test func ignoresOwnEchoAndStaleMessages() {
        var s = PhotoShareSession(selfId: "me")
        #expect(s.handle(.received(.init(message: .init(type: .offer, seq: 1, shareId: "x", senderId: "me", durationMs: 6000), timestampMs: 5)), now: at(0)).isEmpty)
        _ = s.handle(.received(.init(message: .init(type: .offer, seq: 2, shareId: "new", senderId: "them", durationMs: 6000), timestampMs: 50)), now: at(0))
        let fx = s.handle(.received(.init(message: .init(type: .offer, seq: 1, shareId: "old", senderId: "them", durationMs: 6000), timestampMs: 40)), now: at(0))
        #expect(s.incoming?.shareId == "new")
        #expect(fx.allSatisfy { if case .log = $0 { true } else { false } })
    }

    /// Both share at once: each device shows the other's photo; when one ends both fall back cleanly.
    @Test func simultaneousShareAcrossTwoDevices() {
        var a = PhotoShareSession(selfId: "A"), b = PhotoShareSession(selfId: "B")
        func deliver(_ fx: [PhotoShareSession.Effect], to s: inout PhotoShareSession, ts: Int64, now: Date) -> [PhotoShareSession.Effect] {
            var out: [PhotoShareSession.Effect] = []
            for m in sends(fx) { out += s.handle(.received(.init(message: m, timestampMs: ts)), now: now) }
            return out
        }
        // A shares at t=0; B shares at t=2 while A's photo is on screen.
        _ = a.handle(.share(photo("pa")), now: at(0))
        let offerA = a.handle(.shareCreated(photoId: "pa", shareId: "sa"), now: at(0.1))
        _ = deliver(offerA, to: &b, ts: 1, now: at(0.15))
        let readyFromB = b.handle(.incomingLoaded(shareId: "sa", image: .placeholder("pa")), now: at(0.4))
        _ = deliver(readyFromB, to: &a, ts: 2, now: at(0.45))
        #expect(a.display(now: at(1)).photo?.shareId == "sa")   // only A shares → both show A's
        #expect(b.display(now: at(1)).photo?.shareId == "sa")

        _ = b.handle(.share(photo("pb")), now: at(2))
        let offerB = b.handle(.shareCreated(photoId: "pb", shareId: "sb"), now: at(2.1))
        _ = deliver(offerB, to: &a, ts: 3, now: at(2.15))
        let readyFromA = a.handle(.incomingLoaded(shareId: "sb", image: .placeholder("pb")), now: at(2.3))
        _ = deliver(readyFromA, to: &b, ts: 4, now: at(2.35))

        // Both sharing → each sees the other's photo.
        #expect(a.display(now: at(3)).photo?.shareId == "sb")
        #expect(b.display(now: at(3)).photo?.shareId == "sa")

        // A's photo ends (started 0.45 on A) → A sends end; B falls back to its own photo.
        let endA = a.handle(.tick, now: at(6.45))
        _ = deliver(endA, to: &b, ts: 5, now: at(6.5))
        #expect(b.display(now: at(6.5)) == .mine(b.mineRef!))
        #expect(a.display(now: at(6.5)).photo?.shareId == "sb") // A still sees B's
    }

    @Test func swipeCancelSendsCancelAndAudits() {
        var s = PhotoShareSession(selfId: "me")
        _ = s.handle(.share(photo("p1")), now: at(0))
        _ = s.handle(.shareCreated(photoId: "p1", shareId: "s1"), now: at(0))
        _ = s.handle(.tick, now: at(1.5))
        let fx = s.handle(.cancelMine, now: at(3.5))
        #expect(sends(fx).map(\.type) == [.cancel])
        #expect(fx.contains(.markShown(shareId: "s1", shownAt: at(1.5), durationMs: 2000)))
        #expect(s.display(now: at(3.5)) == .selfView)
    }
}
