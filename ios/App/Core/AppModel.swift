import Auth
import Availability
import BackgroundWork
import Calls
import Foundation
import Friends
import Memory
import Messages
import Models
import Networking
import Nudges
import Observation
import PhotoIndex
import Settings
import UIKit
import UserNotifications
import os

/// Composition root: owns every store and routes server events, pushes and CallKit between them.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let config: AppConfig
    let isPreview: Bool
    let session: SessionStore
    let api: NudgeAPI
    let socket: EventSocket
    let friends: FriendsStore
    let messages: MessagesStore
    let memory: MemoryStore
    let settings: SettingsStore
    let nudges: NudgeCenter
    let availability: AvailabilitySync
    let photos: PhotoIndexer
    let call: CallController
    let callKit: CallKitProvider
    let voip: VoIPPushHandler

    var openThreadId: String?
    var pendingAddHandle: String?
    var selectedTab: Tab = .friends
    var socketStatus: EventSocket.Status = .disconnected
    var incoming: IncomingCall?
    private(set) var onboardingComplete: Bool

    private var apnsToken: String?
    private var eventLoop: Task<Void, Never>?
    private var statusLoop: Task<Void, Never>?
    private var started = false
    private let log = Logger(subsystem: "app.nudge", category: "app")

    enum Tab: Hashable { case friends, messages, settings }

    struct IncomingCall: Identifiable, Hashable {
        var id: String { callId }
        var callId: String
        var friend: PublicUser
        var name: String
    }

    init(config: AppConfig = .fromBundle(), preview: Bool = ScreenshotMode.current != nil) {
        self.config = config
        self.isPreview = preview
        let session = SessionStore()
        self.session = session
        let client = APIClient(baseURL: config.apiBaseURL, tokens: session)
        let api = NudgeAPI(client: client)
        self.api = api
        session.attach(api: api)
        let socket = EventSocket(url: config.webSocketURL, tokens: session)
        self.socket = socket
        friends = FriendsStore(api: api)
        messages = MessagesStore(api: api)
        memory = MemoryStore(api: api)
        settings = SettingsStore(api: api)
        nudges = NudgeCenter(api: api, socket: socket)
        availability = AvailabilitySync(api: api)
        photos = PhotoIndexer(api: api)
        call = CallController(api: api, socket: socket, selfId: { [weak session] in session?.userId },
                              idToken: { await MainActor.run { AppModel.shared.session.idToken } })
        let callKit = CallKitProvider()
        self.callKit = callKit
        voip = VoIPPushHandler(callKit: callKit)
        onboardingComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")
        wire()
    }

    private func wire() {
        nudges.onMatched = { [weak self] callId, nudge in
            Task { await self?.startCall(callId: callId, viaCallKit: false, friend: nudge?.friend, name: nudge?.friendName) }
        }
        nudges.onMeUpdated = { [weak self] me in self?.apply(me: me) }
        settings.onMeUpdated = { [weak self] me in self?.apply(me: me) }
        call.onEnded = { [weak self] callId, duration in
            guard let self else { return }
            self.callKit.endCall(callId: callId)
            if let peer = self.call.peer {
                self.memory.callEnded(callId: callId, friendId: peer.id, friendName: self.call.peerName, durationSec: duration,
                                      memoryAllowed: self.settings.settings.memoryEnabled)
            }
        }
        callKit.onAnswer = { [weak self] c in
            Task { await self?.startCall(callId: c.callId, viaCallKit: true, friend: nil, name: c.callerName) }
        }
        callKit.onEnd = { [weak self] c in
            guard let self else { return }
            if self.call.callId == c.callId, self.call.isActive { Task { await self.call.leave() } }
            else { Task { try? await self.api.endCall(c.callId) } }
        }
        callKit.onMute = { [weak self] muted in self?.call.setMuted(muted) }
        voip.onToken = { [weak self] _ in Task { await self?.registerDevice() } }
    }

    // MARK: Lifecycle

    func launch() async {
        guard !isPreview else { return }
        await session.restore()
        if session.status == .signedIn { await didSignIn() }
    }

    func didSignIn() async {
        guard !isPreview, session.status == .signedIn else { return }
        if let me = session.me { apply(me: me) }
        guard !started else { return }
        started = true
        await socket.connect()
        startEventLoop()
        UIApplication.shared.registerForRemoteNotifications()
        await registerDevice()
        _ = try? await api.updateMe(MePatch(tz: TimeZone.current.identifier))
        await nudges.refreshActive()
        if availability.isAuthorized { availability.startObserving(); await availability.sync(reason: "launch") }
        if PhotoIndexer.isAuthorized { photos.startObserving(); Task { await photos.run(reason: "launch") } }
        BackgroundScheduler.scheduleRefresh()
        BackgroundScheduler.schedulePhotos()
    }

    func foregrounded() async {
        guard !isPreview, session.status == .signedIn else { return }
        await availability.sync(reason: "foreground")
        await nudges.refreshActive()
    }

    func signOut() {
        Task { await socket.disconnect() }
        eventLoop?.cancel()
        statusLoop?.cancel()
        started = false
        session.signOut()
    }

    func completeOnboarding() {
        onboardingComplete = true
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
    }

    func apply(me: MeResponse) {
        session.update(me: me)
        settings.sync(from: me)
        photos.includeScreenshots = me.user.settings.includeScreenshots
        photos.enabled = me.user.settings.photoIndexing
        call.photoMode = me.user.settings.photoMode
        let shared = UserDefaults(suiteName: config.appGroup)
        shared?.set(me.user.displayName, forKey: "me.displayName")
        shared?.set(me.user.id, forKey: "me.id")
    }

    // MARK: Events

    private func startEventLoop() {
        eventLoop?.cancel()
        eventLoop = Task { [weak self] in
            guard let stream = await self?.socket.events() else { return }
            for await event in stream { self?.route(event) }
        }
        statusLoop?.cancel()
        statusLoop = Task { [weak self] in
            guard let stream = await self?.socket.statusUpdates() else { return }
            for await s in stream { self?.socketStatus = s }
        }
    }

    func route(_ event: ServerEvent) {
        nudges.apply(event)
        messages.apply(event, openThread: openThreadId)
        Task { await friends.apply(event) }
        switch event {
        case .photoSuggestion(let s): call.receive(suggestion: s)
        case .callEnded(let callId):
            callKit.reportRemoteEnded(callId: callId)
            if call.callId == callId { Task { await call.remoteEnded() } }
        case .callSummaryReady(let callId, _): Task { await memory.summaryReady(callId: callId) }
        default: break
        }
    }

    // MARK: Calls

    func startCall(callId: String, viaCallKit: Bool, friend: PublicUser?, name: String?) async {
        incoming = nil
        await nudges.clearWaiting()
        call.photoMode = settings.settings.photoMode
        await call.join(callId: callId, viaCallKit: viaCallKit)
    }

    func callNow(_ friend: Friend) async {
        do {
            let n = try await api.callNow(friendId: friend.id)
            await nudges.accept(n)
        } catch {
            nudges.error = error.localizedDescription
        }
    }

    // MARK: Push

    func didRegister(apnsToken token: Data) {
        apnsToken = token.map { String(format: "%02x", $0) }.joined()
        Task { await registerDevice() }
    }

    func registerDevice() async {
        guard !isPreview, session.hasSession else { return }
        let reg = DeviceRegistration(
            deviceId: UIDevice.current.identifierForVendor?.uuidString ?? "unknown",
            apnsToken: apnsToken, voipToken: voip.token, apnsEnv: APNsEnvironment.current,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
        do { try await api.registerDevice(reg) } catch { log.error("register device: \(String(describing: error), privacy: .public)") }
    }

    /// Background (content-available) pushes.
    func handleBackgroundPush(_ info: [AnyHashable: Any]) async {
        switch (info["type"] as? String).flatMap(PushKind.init(rawValue:)) {
        case .availabilityCheck, .calendarSync: await availability.sync(reason: "silent push")
        case .nudgeCleanup: if let id = info["nudgeId"] as? String { nudges.removeDelivered(nudgeId: id) }
        default: break
        }
    }

    // MARK: Deep links

    func open(url: URL) {
        if let handle = AddFriendLink.handle(from: url) {
            pendingAddHandle = handle
            selectedTab = .friends
        }
    }
}

enum APNsEnvironment {
    /// Reads `aps-environment` from the embedded provisioning profile (TestFlight/App Store → production).
    static var current: DeviceRegistration.APNsEnvironment {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            #if DEBUG
            return .sandbox
            #else
            return .production
            #endif
        }
        return parse(profile: data) ?? .production
    }

    static func parse(profile data: Data) -> DeviceRegistration.APNsEnvironment? {
        let text = String(decoding: data, as: UTF8.self)
        guard let keyRange = text.range(of: "<key>aps-environment</key>") else { return nil }
        let rest = text[keyRange.upperBound...]
        guard let s = rest.range(of: "<string>"), let e = rest.range(of: "</string>") else { return nil }
        return rest[s.upperBound..<e.lowerBound] == "development" ? .sandbox : .production
    }
}
