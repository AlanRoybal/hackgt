import Foundation
import Testing
@testable import Models
@testable import Nearby

@Suite("Tap to add — ACC-13")
struct TapDetectionTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func closenessRampsFromGlowDistanceToTouch() {
        #expect(TapDetection.closeness(distance: 2) == 0)
        #expect(TapDetection.closeness(distance: TapDetection.glowDistance) == 0)
        #expect(TapDetection.closeness(distance: TapDetection.touchDistance) == 1)
        #expect(TapDetection.closeness(distance: 0.01) == 1)
        let mid = TapDetection.closeness(distance: 0.36)
        #expect(mid > 0.4 && mid < 0.6)
    }

    @Test func proximityNeedsConsecutiveCloseReadings() {
        var p = ProximityTracker()
        // A noisy far sample resets the count; it fires once; losing the peer clears it.
        let fired = [0.4, 0.08, 0.3, 0.08, 0.07, 0.07, nil].map { (d: Float?) in p.add(distance: d) }
        #expect(fired == [false, false, false, false, true, false, false])
        #expect(p.closeness == 0)
    }

    private func feed(_ d: inout BumpDetector, _ samples: [Double], from start: Date) -> [Int] {
        samples.enumerated().compactMap { i, m in d.add(magnitude: m, at: start.addingTimeInterval(Double(i) / 100)) ? i : nil }
    }

    @Test func knockAfterHoldingStillIsABump() {
        var d = BumpDetector()
        let hits = feed(&d, Array(repeating: 0.05, count: 20) + [1.4, 0.9, 0.2] + Array(repeating: 0.05, count: 10), from: t0)
        #expect(hits == [20])
    }

    @Test func shakingIsNotABump() {
        var d = BumpDetector()
        let shaking = (0..<60).map { $0 % 4 < 2 ? 1.2 : 0.4 }
        let hits = feed(&d, shaking, from: t0)
        #expect(hits.isEmpty)
    }

    @Test func secondKnockInsideRefractoryIsIgnored() {
        var d = BumpDetector()
        let quiet = Array(repeating: 0.05, count: 20)
        let hits = feed(&d, quiet + [1.2] + quiet + [1.2] + quiet + quiet + quiet + [1.2], from: t0)
        #expect(hits == [20, 102])
    }

    @Test func bumpsPairWithinTheWindow() {
        #expect(TapDetection.bumpsMatch(local: [t0], arrival: t0.addingTimeInterval(0.2)))
        #expect(TapDetection.bumpsMatch(local: [t0.addingTimeInterval(0.3)], arrival: t0))
        #expect(!TapDetection.bumpsMatch(local: [t0], arrival: t0.addingTimeInterval(0.9)))
        #expect(!TapDetection.bumpsMatch(local: [], arrival: t0))
    }

    @Test func wireRoundTrips() throws {
        let hello = TapHello(userId: "u_1", token: "tok", rangingToken: Data([1, 2]))
        #expect(try TapWire.decode(TapWire.hello(hello).encoded()) == .hello(hello))
        #expect(try TapWire.decode(TapWire.bump.encoded()) == .bump)
    }

    @Test func tapResultDecodesServerStatuses() throws {
        let json = #"{"status":"already_friends","user":{"id":"u_2","handle":"sam","displayName":"Sam"}}"#
        let r = try NudgeJSON.decoder().decode(TapResult.self, from: Data(json.utf8))
        #expect(r.status == .alreadyFriends)
        #expect(r.user?.id == "u_2")
        let pending = try NudgeJSON.decoder().decode(TapResult.self, from: Data(#"{"status":"pending"}"#.utf8))
        #expect(pending.status == .pending && pending.user == nil)
    }
}
