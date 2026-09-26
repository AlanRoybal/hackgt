import CoreGraphics
import Foundation
import Testing
@testable import Availability
@testable import Calls
@testable import Friends
@testable import Models
@testable import PhotoIndex

@Suite("HandleRule — ACC-3")
struct HandleRuleTests {
    @Test(arguments: ["alan", "a_b.c", "abc", "x1234567890123456789", "@Alan"])
    func valid(_ h: String) { #expect(HandleRule.validate(h) == nil) }

    @Test(arguments: [
        ("ab", HandleRule.Problem.tooShort), ("a23456789012345678901", .tooLong), ("al an", .badCharacters),
        ("émile", .badCharacters), (".alan", .dotPlacement), ("alan.", .dotPlacement), ("al..an", .dotPlacement),
        ("admin", .reserved), ("Nudge", .reserved), ("al-an", .badCharacters),
    ])
    func invalid(_ h: String, _ p: HandleRule.Problem) { #expect(HandleRule.validate(h) == p) }

    @Test func normalizes() { #expect(HandleRule.normalize("  @Alan.R ") == "alan.r") }
}

@Suite("PhoneHasher — ACC-5/7")
struct PhoneHasherTests {
    let hasher = PhoneHasher(defaultRegion: "US")

    @Test(arguments: [("(415) 555-2671", "+14155552671"), ("415.555.2671", "+14155552671"), ("+44 20 7946 0958", "+442079460958"), ("1-415-555-2671", "+14155552671")])
    func e164(_ raw: String, _ expected: String) { #expect(hasher.e164(raw) == expected) }

    @Test func rejectsGarbage() { #expect(hasher.e164("hello") == nil) }

    @Test func hashIsSHA256OfE164() {
        // echo -n "+14155552671" | shasum -a 256
        #expect(PhoneHasher.hash(e164: "+14155552671") == "cb6880e416769253645cb9c6b8989154bf66a56a77fc14c81fb1019663cbb928")
    }

    @Test func dedupesEquivalentNumbers() {
        let hs = hasher.hashes(for: ["(415) 555-2671", "+1 415 555 2671", "nope"])
        #expect(hs.count == 1)
        #expect(hs[0] == PhoneHasher.hash(e164: "+14155552671"))
    }
}

@Suite("BusyExtractor — AV-1/2")
struct BusyExtractorTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func h(_ x: Double) -> Date { now.addingTimeInterval(x * 3600) }

    @Test func dropsFreeAndDisabledAndMerges() {
        let spans = [
            CalendarSpan(start: h(1), end: h(2), availability: .busy, calendarId: "work"),
            CalendarSpan(start: h(1.5), end: h(3), availability: .notSupported, calendarId: "work"),
            CalendarSpan(start: h(3), end: h(4), availability: .tentative, calendarId: "home"),   // touches → merge
            CalendarSpan(start: h(5), end: h(6), availability: .free, calendarId: "work"),        // free → ignored
            CalendarSpan(start: h(7), end: h(8), availability: .busy, calendarId: "hidden"),      // disabled
        ]
        let blocks = BusyExtractor.busyBlocks(from: spans, disabledCalendarIds: ["hidden"], now: now)
        #expect(blocks == [BusyBlock(start: h(1), end: h(4))])
    }

    @Test func clipsToWindow() {
        let spans = [CalendarSpan(start: h(-1), end: h(1), availability: .busy, calendarId: "c"),
                     CalendarSpan(start: h(24 * 7 - 1), end: h(24 * 7 + 5), availability: .busy, calendarId: "c"),
                     CalendarSpan(start: h(24 * 8), end: h(24 * 8 + 1), availability: .busy, calendarId: "c")]
        let blocks = BusyExtractor.busyBlocks(from: spans, disabledCalendarIds: [], now: now)
        #expect(blocks == [BusyBlock(start: now, end: h(1)), BusyBlock(start: h(24 * 7 - 1), end: h(24 * 7))])
    }

    @Test func allDayOnlyWhenExplicitlyBusy() {
        let spans = [CalendarSpan(start: h(0), end: h(24), availability: .notSupported, calendarId: "birthdays", isAllDay: true),
                     CalendarSpan(start: h(24), end: h(48), availability: .busy, calendarId: "c", isAllDay: true)]
        #expect(BusyExtractor.busyBlocks(from: spans, disabledCalendarIds: [], now: now) == [BusyBlock(start: h(24), end: h(48))])
    }

    @Test func freeUntil() {
        let blocks = [BusyBlock(start: h(1), end: h(2))]
        #expect(BusyExtractor.freeUntil(blocks, now: now) == (true, h(1)))
        #expect(BusyExtractor.freeUntil(blocks, now: h(1.5)).free == false)
        #expect(BusyExtractor.freeUntil(blocks, now: h(3)).until == nil)
    }
}

@Suite("DrivingReporter — AV-3")
struct DrivingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    @Test func mediumConfidenceAutomotiveCounts() {
        #expect(DrivingReporter.isDriving([.init(automotive: true, confidence: 1, start: now.addingTimeInterval(-300))], now: now))
        #expect(!DrivingReporter.isDriving([.init(automotive: true, confidence: 0, start: now.addingTimeInterval(-300))], now: now))
        #expect(!DrivingReporter.isDriving([.init(automotive: false, confidence: 2, start: now.addingTimeInterval(-60))], now: now))
        #expect(!DrivingReporter.isDriving([], now: now))
    }
}

@Suite("AddFriendLink — ACC-8")
struct ShareLinkTests {
    @Test func parses() {
        #expect(AddFriendLink.handle(from: URL(string: "nudge://add/alan.r")!) == "alan.r")
        #expect(AddFriendLink.handle(from: URL(string: "NUDGE://add/Alan")!) == "alan")
        #expect(AddFriendLink.handle(from: URL(string: "nudge://add/")!) == nil)
        #expect(AddFriendLink.handle(from: URL(string: "nudge://call/alan")!) == nil)
        #expect(AddFriendLink.handle(from: URL(string: "https://add/alan")!) == nil)
        #expect(AddFriendLink.handle(from: URL(string: "nudge://add/a")!) == nil)
        #expect(AddFriendLink.handle(from: URL(string: "nudge://add/alan/extra")!) == nil)
    }

    @Test func builds() {
        #expect(AddFriendLink.url(for: "@Alan").absoluteString == "nudge://add/alan")
        #expect(AddFriendLink.shareText(for: "alan").contains("@alan"))
    }
}

@Suite("SnapGeometry — CALL-1")
struct SnapTests {
    let container = CGSize(width: 402, height: 874)
    let window = CGSize(width: 110, height: 160)
    let insets = EdgeInsetsLike(top: 60, leading: 16, bottom: 120, trailing: 16)

    @Test func projectionMatchesApple() {
        #expect(abs(SnapGeometry.project(1000) - 499) < 0.5)
        #expect(SnapGeometry.project(0) == 0)
    }

    @Test func releaseWithoutVelocityPicksNearest() {
        let c = SnapGeometry.target(release: CGPoint(x: 80, y: 700), velocity: .zero, container: container, window: window, insets: insets)
        #expect(c == .bottomLeading)
    }

    @Test func flickCarriesToFarCorner() {
        // Released near top-left but flicked right and down hard.
        let c = SnapGeometry.target(release: CGPoint(x: 120, y: 200), velocity: CGVector(dx: 900, dy: 1400), container: container, window: window, insets: insets)
        #expect(c == .bottomTrailing)
    }

    @Test func rubberbandIsSubLinear() {
        let r = SnapGeometry.rubberband(100, dimension: 400)
        #expect(r > 0 && r < 100)
        #expect(SnapGeometry.rubberband(-100, dimension: 400) == -r)
    }
}

@Suite("PhotoSelector — PHO-1")
struct PhotoSelectorTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func d(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }

    @Test func rules() {
        let assets = [
            AssetDescriptor(localIdentifier: "recent", creationDate: d(2)),
            AssetDescriptor(localIdentifier: "old", creationDate: d(31)),
            AssetDescriptor(localIdentifier: "edge", creationDate: d(29.9)),
            AssetDescriptor(localIdentifier: "hidden", creationDate: d(1), isHidden: true),
            AssetDescriptor(localIdentifier: "shot", creationDate: d(1), isScreenshot: true),
            AssetDescriptor(localIdentifier: "video", creationDate: d(1), isImage: false),
            AssetDescriptor(localIdentifier: "nodate", creationDate: nil),
        ]
        #expect(PhotoSelector.select(assets, includeScreenshots: false, now: now).map(\.localIdentifier) == ["recent", "edge"])
        #expect(PhotoSelector.select(assets, includeScreenshots: true, now: now).map(\.localIdentifier) == ["recent", "edge", "shot"])
    }

    @Test func resizeNeverUpscales() {
        #expect(PhotoSelector.targetSize(width: 4032, height: 3024) == CGSize(width: 1024, height: 768))
        #expect(PhotoSelector.targetSize(width: 3024, height: 4032) == CGSize(width: 768, height: 1024))
        #expect(PhotoSelector.targetSize(width: 800, height: 600) == CGSize(width: 800, height: 600))
    }

    @Test func hashIsStableAndOpaque() {
        let a = PhotoSelector.assetHash("ABC/L0/001")
        #expect(a == PhotoSelector.assetHash("ABC/L0/001"))
        #expect(a.count == 32 && !a.contains("ABC"))
    }
}

@Suite("Models — contract decoding")
struct ContractTests {
    @Test func decodesNudgeFromBackendJSON() throws {
        let json = #"""
        {"id":"n_1","kind":"auto","friend":{"id":"u_2","handle":"mom","displayName":"Linda"},"nickname":"Mom",
         "state":"accepted_by_one","myResponse":"accepted","window":{"start":"2026-09-26T15:00:00.000Z","end":"2026-09-26T15:10:00Z"},
         "minutes":10,"title":"Mom is free too","body":"You and Mom are both free for the next 10 minutes. Call?",
         "expiresAt":"2026-09-26T15:03:00.000Z"}
        """#
        let n = try NudgeJSON.decoder().decode(Nudge.self, from: Data(json.utf8))
        #expect(n.state == .acceptedByOne && n.myResponse == .accepted && n.friendName == "Mom" && n.minutes == 10)
    }

    @Test func decodesServerEvents() throws {
        let e = try ServerEvent.decode(Data(#"{"type":"call.matched","callId":"c_1","nudgeId":"n_1"}"#.utf8))
        #expect(e == .callMatched(callId: "c_1", nudgeId: "n_1"))
        let s = try ServerEvent.decode(Data(#"{"type":"photo.suggestion","callId":"c","suggestionId":"sg","photoId":"p","thumbUrl":"https://x/y.jpg","query":"hike","confidence":0.8,"auto":false}"#.utf8))
        guard case .photoSuggestion(let p) = s else { Issue.record("wrong event"); return }
        #expect(p.photoId == "p" && !p.auto)
        #expect(try ServerEvent.decode(Data(#"{"type":"something.new"}"#.utf8)) == .unknown("something.new"))
    }

    @Test func encodesClientActions() throws {
        let w = String(decoding: try ClientAction.waiting(nudgeId: nil).encoded(), as: UTF8.self)
        #expect(w == #"{"action":"waiting","nudgeId":null}"#)
        let t = String(decoding: try ClientAction.transcript(.init(callId: "c", segId: "s", text: "hi", startMs: 0, endMs: 5, clientTs: 9)).encoded(), as: UTF8.self)
        #expect(t.contains(#""action":"transcript""#) && t.contains(#""segId":"s""#))
    }

    @Test func frequencyLessOftenFloorsAtLow() {
        #expect(Frequency.high.lessOften == .normal)
        #expect(Frequency.normal.lessOften == .low)
        #expect(Frequency.low.lessOften == .low)
    }

    @Test func settingsDefaultsMatchSpec() throws {
        let s = Settings.default
        #expect(s.frequency == .normal && s.quietStart == "00:00" && s.quietEnd == "08:00" && s.minWindowMin == 5)
        #expect(s.skipBehavior == .message && s.photoMode == .ask && !s.includeScreenshots && s.memoryEnabled)
        let json = String(decoding: try NudgeJSON.encoder().encode(SettingsPatch(s)), as: UTF8.self)
        #expect(json.contains(#""photoMode":"ask""#))
    }

    @Test func summary202() throws {
        // `{ pending: true }` → nil summary (handled in NudgeAPI.summary)
        let d = try NudgeJSON.decoder().decode(CallSummary.self, from: Data(#"{"callId":"c","summary":"s","durationSec":60,"createdAt":"2026-09-26T15:00:00Z","topics":[]}"#.utf8))
        #expect(d.durationSec == 60)
    }

    @Test func memoriesDecodeCalendarDayFollowUp() throws {
        // Topics used to come back with followUpAfter as a bare day, which failed the whole payload.
        let json = #"{"topics":[{"id":"t","title":"the exam","aboutUserId":"u","summary":"s","followUpAfter":"2026-09-29","status":"open","sourceCallId":"c"}],"summaries":[{"callId":"c","summary":"s","durationSec":70,"createdAt":"2026-09-26T17:26:54.846Z","topics":[]}]}"#
        let m = try NudgeJSON.decoder().decode(Memories.self, from: Data(json.utf8))
        #expect(m.topics.first?.followUpAfter == NudgeJSON.parseDate("2026-09-29T00:00:00Z"))
        #expect(m.summaries.count == 1)
    }
}
