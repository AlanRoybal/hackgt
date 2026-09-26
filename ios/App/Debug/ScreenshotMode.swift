import DesignSystem
import Memory
import Models
import Nudges
import PhotoShare
import SwiftUI

/// `-screenshotScreen <id>` renders one screen with mock data and no network (DEBUG only).
enum ScreenshotMode {
    static var current: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-screenshotScreen"), i + 1 < args.count { return args[i + 1] }
        #endif
        return nil
    }

    /// Screenshot capture of the Reduce Motion variant (the simulator setting needs a respring to apply).
    static var forceReduceMotion: Bool { ProcessInfo.processInfo.arguments.contains("-forceReduceMotion") }

    /// Every screen id the capture script walks through (keep in sync with ios/scripts/screenshots.sh).
    static let all: [String] = [
        "welcome", "signin", "terms", "handle", "phone", "phone-code",
        "permission-notifications", "permission-calendar", "permission-photos", "permission-contacts",
        "permission-camera", "permission-focus", "permission-motion", "permission-denied", "add-first-friends",
        "friends", "friends-empty", "friends-loading", "friends-offline", "add-friends-search", "add-friends-contacts",
        "add-friends-invite", "requests", "friend-profile", "friend-profile-empty",
        "messages", "messages-empty", "thread",
        "banner", "toast", "waiting", "waiting-declined", "waiting-expired", "incoming",
        "call-connecting", "call-connected", "call-suggestion", "call-mine", "call-other", "call-both", "call-queue",
        "call-auto", "call-muted", "call-reconnecting", "summary", "summary-pending",
        "settings", "settings-nudges", "settings-calendars", "settings-photos", "settings-memory", "settings-account",
        "delete-account",
    ]
}

struct ScreenshotHost: View {
    let screen: String
    private let app = AppModel.shared

    init(screen: String) {
        self.screen = screen
        MockData.configure(AppModel.shared, for: screen)
    }

    var body: some View {
        content
            .environment(app)
            .transformEnvironment(\._accessibilityReduceMotion) { if ScreenshotMode.forceReduceMotion { $0 = true } }
    }

    @ViewBuilder var content: some View {
        switch screen {
        case "welcome": WelcomeView(onContinue: {})
        case "signin": NavigationStack { SignInView() }
        case "terms": TermsView()
        case "handle": HandleView()
        case "phone": PhoneView(onDone: {})
        case "phone-code": PhoneCodePreview()
        case "permission-denied": PermissionPrimerView(kind: .photos, forceDenied: true, onDone: {})
        case let s where s.hasPrefix("permission-"):
            PermissionPrimerView(kind: permission(s), onDone: {})
        case "add-first-friends": AddFirstFriendsView(onDone: {})
        case "friends", "friends-empty", "friends-loading", "friends-offline", "banner", "toast": MainView()
        case "add-friends-search", "add-friends-contacts", "add-friends-invite": AddFriendsPreview(screen: screen)
        case "requests": FriendRequestsView()
        case "friend-profile", "friend-profile-empty": NavigationStack { FriendProfileView(friendId: MockData.mom.id) }
        case "messages", "messages-empty": MainView()
        case "thread": NavigationStack { ThreadView(friendId: MockData.mom.id) }
        case "waiting", "waiting-declined", "waiting-expired", "incoming", "summary", "summary-pending": FlowContainer()
        case let s where s.hasPrefix("call-"): FlowContainer()
        case "settings": MainView()
        case "settings-nudges": NavigationStack { NudgeSettingsView() }
        case "settings-calendars": NavigationStack { CalendarSettingsView() }
        case "settings-photos": NavigationStack { PhotoSettingsView() }
        case "settings-memory": NavigationStack { MemorySettingsView() }
        case "settings-account": NavigationStack { AccountSettingsView() }
        case "delete-account": Color.clear.sheet(isPresented: .constant(true)) { DeleteAccountSheet().environment(app) }
        default: Text("Unknown screen \(screen)")
        }
    }

    func permission(_ s: String) -> PermissionKind {
        switch s {
        case "permission-calendar": .calendar
        case "permission-photos": .photos
        case "permission-contacts": .contacts
        case "permission-camera": .cameraMic
        case "permission-focus": .focus
        case "permission-motion": .motion
        default: .notifications
        }
    }
}

private struct PhoneCodePreview: View {
    var body: some View { PhoneView(onDone: {}, startSent: true) }
}

private struct AddFriendsPreview: View {
    let screen: String
    var body: some View {
        AddFriendsView(initialSegment: screen == "add-friends-contacts" ? .contacts : screen == "add-friends-invite" ? .invite : .search,
                       initialQuery: screen == "add-friends-search" ? "sa" : "")
    }
}

// MARK: Mock data

@MainActor
enum MockData {
    /// Fixed mid-afternoon so "free until" times read naturally in captures.
    static let now = Date()
    static let afternoonBase = Calendar.current.date(bySettingHour: 15, minute: 32, second: 0, of: Date()) ?? Date()
    static func afternoon(_ m: Double) -> Date { afternoonBase.addingTimeInterval(m * 60) }
    static func minutes(_ m: Double) -> Date { now.addingTimeInterval(m * 60) }

    static let me = UserDTO(id: "u_me", handle: "alan", displayName: "Alan Roybal", phoneVerified: true, tosVersion: "1")
    static let mom = PublicUser(id: "u_mom", handle: "linda.r", displayName: "Linda Roybal")
    static let sam = PublicUser(id: "u_sam", handle: "samk", displayName: "Sam Kim")
    static let priya = PublicUser(id: "u_priya", handle: "priya", displayName: "Priya Natarajan")
    static let jordan = PublicUser(id: "u_jordan", handle: "jordan_b", displayName: "Jordan Blake")
    static let dad = PublicUser(id: "u_dad", handle: "rroybal", displayName: "Ray Roybal")

    static var friends: [Friend] {
        [
            Friend(user: mom, nickname: "Mom", since: minutes(-90_000), lastCallAt: minutes(-4_000), freeNow: true, freeUntil: afternoon(25)),
            Friend(user: sam, since: minutes(-50_000), lastCallAt: minutes(-12_000), freeNow: true, freeUntil: afternoon(55)),
            Friend(user: priya, since: minutes(-30_000), lastCallAt: minutes(-2_000), freeNow: false),
            Friend(user: jordan, since: minutes(-10_000), freeNow: false),
            Friend(user: dad, nickname: "Dad", since: minutes(-90_000), lastCallAt: minutes(-20_000), freeNow: false),
        ]
    }

    static var nudge: Nudge {
        Nudge(id: "n_1", friend: mom, nickname: "Mom", state: .pending, window: TimeWindow(start: afternoon(0), end: afternoon(10)), minutes: 10,
              title: "Mom is free too", body: "You and Mom are both free for the next 10 minutes. Call?", expiresAt: Date().addingTimeInterval(161))
    }

    static var topics: [Topic] {
        [Topic(id: "t1", title: "Physics exam", aboutUserId: mom.id, summary: "Mom is helping Alan study; exam on Thursday.", followUpAfter: minutes(3000)),
         Topic(id: "t2", title: "Denver trip", aboutUserId: me.id, summary: "Planning a trip in November."),
         Topic(id: "t3", title: "New garden beds", aboutUserId: mom.id, summary: "Building raised beds this weekend.")]
    }

    static var summaries: [CallSummary] {
        [CallSummary(callId: "c_1", summary: "Talked about the physics exam on Thursday and Mom's new garden beds. Alan shared photos from the Saturday hike.",
                     durationSec: 754, createdAt: minutes(-4_000), topics: topics)]
    }

    static func messages(for friend: String) -> [Message] {
        [
            Message(id: "m1", friendId: friend, senderId: "system", body: "Called · 12 min", kind: .system, createdAt: minutes(-4_000)),
            Message(id: "m2", friendId: friend, senderId: mom.id, body: "Good luck on Thursday! Call me after?", kind: .user, createdAt: minutes(-3_900)),
            Message(id: "m3", friendId: friend, senderId: me.id, body: "Will do. Thanks for the help with the review sheet", kind: .user, createdAt: minutes(-3_890)),
            Message(id: "m4", friendId: friend, senderId: "system", body: "Missed nudge · 3:40 PM", kind: .system, createdAt: minutes(-200)),
            Message(id: "m5", friendId: friend, senderId: mom.id, body: "In a meeting until 4. I'll call you right after!", kind: .autoFollowup, createdAt: minutes(-199)),
        ]
    }

    static func configure(_ app: AppModel, for screen: String) {
        app.session.preview(me: MeResponse(user: me, needsTos: false, needsHandle: false, currentTosVersion: "1"))
        app.settings.preview(Settings.default)
        let requests = FriendRequests(incoming: [FriendRequestEntry(user: PublicUser(id: "u_taylor", handle: "taylor", displayName: "Taylor Chen"), createdAt: minutes(-120))],
                                      outgoing: [FriendRequestEntry(user: PublicUser(id: "u_nina", handle: "nina.o", displayName: "Nina Okafor"), createdAt: minutes(-600))])
        let search = [SearchResult(id: sam.id, handle: sam.handle, displayName: sam.displayName, relation: .friends),
                      SearchResult(id: "u_sara", handle: "sara.m", displayName: "Sara Martinez", relation: .none),
                      SearchResult(id: "u_sasha", handle: "sasha", displayName: "Sasha Ivanova", relation: .requested)]
        let contacts = [SearchResult(id: "u_nina", handle: "nina.o", displayName: "Nina Okafor", relation: .requested),
                        SearchResult(id: "u_eli", handle: "eli", displayName: "Eli Rosen", relation: .none),
                        SearchResult(id: "u_taylor", handle: "taylor", displayName: "Taylor Chen", relation: .incoming)]
        switch screen {
        case "friends-empty": app.friends.preview(friends: [])
        case "friends-loading": break
        default: app.friends.preview(friends: friends, requests: requests, search: search, contacts: contacts,
                                     blocked: [PublicUser(id: "u_x", handle: "spam", displayName: "Unknown Caller")])
        }
        if screen == "friends-offline" { app.socketStatus = .disconnected } else { app.socketStatus = .connected }
        if screen == "add-first-friends" { app.friends.preview(friends: [], contacts: contacts) }

        let convos = [Conversation(friend: mom, nickname: "Mom", lastMessage: messages(for: mom.id).last, unread: 1),
                      Conversation(friend: sam, lastMessage: Message(id: "s1", friendId: sam.id, senderId: me.id, body: "Tomorrow works!", kind: .user, createdAt: minutes(-1_500))),
                      Conversation(friend: priya, lastMessage: Message(id: "p1", friendId: priya.id, senderId: "system", body: "Called · 23 min", kind: .system, createdAt: minutes(-2_000)))]
        app.messages.preview(conversations: screen == "messages-empty" ? [] : convos, threads: [mom.id: messages(for: mom.id)])

        app.memory.preview(friendId: mom.id, memories: screen == "friend-profile-empty" ? Memories() : Memories(topics: topics, summaries: summaries),
                           history: screen == "friend-profile-empty" ? [] : [CallHistoryEntry(callId: "c_1", startedAt: minutes(-4_000), durationSec: 754),
                                                                            CallHistoryEntry(callId: "c_0", startedAt: minutes(-14_000), durationSec: 1_320)])
        app.memory.preview(friendId: sam.id, memories: Memories(topics: [Topic(id: "t9", title: "Half marathon", aboutUserId: sam.id, summary: "")]))
        app.photos.preview(status: PhotoStatus(indexed: 132, excluded: 4, pending: screen == "settings-photos" ? 9 : 0), running: false)
        app.availability.preview(calendars: [
            .init(id: "c1", title: "Personal", colorHex: "#5B8DEF", source: "iCloud"),
            .init(id: "c2", title: "Classes", colorHex: "#E6A23C", source: "iCloud"),
            .init(id: "c3", title: "Work", colorHex: "#8E6CEF", source: "Google (via Apple Calendar)"),
            .init(id: "c4", title: "US Holidays", colorHex: "#67C23A", source: "Subscribed"),
        ], disabled: ["c4"])

        switch screen {
        case "messages", "messages-empty": app.selectedTab = .messages
        case "settings": app.selectedTab = .settings
        default: app.selectedTab = .friends
        }

        // Nudge surfaces
        switch screen {
        case "banner": app.nudges.preview(banner: nudge)
        case "toast": app.nudges.preview(toast: ToastMessage(text: "Nudges set to Low", action: .undoFrequency, actionTitle: "Undo"))
        case "waiting": app.nudges.preview(waiting: withState(nudge, .acceptedByOne, mine: .accepted))
        case "waiting-declined":
            app.nudges.preview(waiting: withState(nudge, .skipped, mine: .accepted, theirs: .skipped))
        case "waiting-expired": app.nudges.preview(waiting: withState(nudge, .expired, mine: .accepted, theirs: .expired))
        case "incoming": app.incoming = AppModel.IncomingCall(callId: "c_2", friend: mom, name: "Mom")
        default: break
        }

        // Calls
        let suggestion = PhotoSuggestion(callId: "c_2", suggestionId: "sg1", photoId: "p1", thumbUrl: URL(string: "https://example.invalid/t.jpg")!,
                                         query: "hike last weekend", confidence: 0.82, auto: false)
        func photo(_ id: String, _ sender: String, _ name: String, qi: Int = 0, ql: Int = 1) -> PhotoRef {
            PhotoRef(shareId: id, senderId: sender, image: .placeholder(name), startedAt: now, durationMs: 6000, queueIndex: qi, queueLength: ql)
        }
        switch screen {
        case "call-connecting": app.call.preview(peer: mom, peerName: "Mom", phase: .connecting)
        case "call-connected": app.call.preview(peer: mom, peerName: "Mom", phase: .connected)
        case "call-suggestion": app.call.preview(peer: mom, peerName: "Mom", phase: .connected, suggestion: suggestion)
        case "call-mine": app.call.preview(peer: mom, peerName: "Mom", phase: .connected, display: .mine(photo("s1", me.id, "hike")))
        case "call-other": app.call.preview(peer: mom, peerName: "Mom", phase: .connected, display: .other(photo("s2", mom.id, "cake")))
        case "call-both": app.call.preview(peer: mom, peerName: "Mom", phase: .connected, display: .other(photo("s3", mom.id, "garden dog")))
        case "call-queue": app.call.preview(peer: mom, peerName: "Mom", phase: .connected, display: .mine(photo("s4", me.id, "beach", qi: 1, ql: 3)))
        case "call-auto": app.call.preview(peer: mom, peerName: "Mom", phase: .connected, autoShown: suggestion, display: .mine(photo("s5", me.id, "hike")))
        case "call-muted": app.call.preview(peer: mom, peerName: "Mom", phase: .connected, muted: true, cameraOn: false, remoteCameraOff: true)
        case "call-reconnecting": app.call.preview(peer: mom, peerName: "Mom", phase: .reconnecting, poorNetwork: true)
        case "summary":
            app.memory.preview(friendId: mom.id, memories: Memories(topics: topics), pending: .init(callId: "c_2", friendId: mom.id, friendName: "Mom", durationSec: 754, summary: summaries[0]))
        case "summary-pending":
            app.memory.preview(friendId: mom.id, memories: Memories(), pending: .init(callId: "c_2", friendId: mom.id, friendName: "Mom", durationSec: 754))
        default: break
        }
    }

    static func withState(_ n: Nudge, _ s: NudgeState, mine: NudgeResponse?, theirs: NudgeResponse? = nil) -> Nudge {
        var n = n
        n.state = s
        n.myResponse = mine
        n.theirResponse = theirs
        return n
    }
}
