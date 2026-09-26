import CoreMotion
import Foundation
import Models
import NearbyInteraction
import Networking
import Observation
import os

/// Tap phones to become friends (ACC-13), like NameDrop. While the app is open, it finds other phones with
/// Nudge open, swaps tap tokens, and watches for the two phones touching (UWB distance, or matching bumps).
/// Then it asks the server to befriend them; the friendship forms once both phones have asked.
/// People who are already friends are ignored from the moment their phone says hello.
@MainActor
@Observable
public final class NearbyTapService {
    public enum Phase: Equatable, Sendable {
        case idle
        /// A phone that isn't a friend yet is getting close (UWB only). `closeness` is 0...1.
        case near(closeness: Double)
        /// The phones touched; waiting on the server.
        case connecting
        case added(PublicUser)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var isRunning = false

    /// The signed-in user's id. Nil means don't advertise.
    @ObservationIgnored public var me: () -> String? = { nil }
    /// Already friends: do nothing with this phone.
    @ObservationIgnored public var isFriend: (String) -> Bool = { _ in false }
    @ObservationIgnored public var onAdded: ((PublicUser) -> Void)?

    private struct Peer {
        var hello: TapHello?
        var ranging: RangingSession?
        var tracker = ProximityTracker()
        var lastBumpArrival: Date?
    }

    private let api: NudgeAPI
    @ObservationIgnored private var link: TapLink?
    @ObservationIgnored private var peers: [String: Peer] = [:]
    @ObservationIgnored private var token: TapToken?
    @ObservationIgnored private var tokenTask: Task<Void, Never>?
    @ObservationIgnored private var redeemTask: Task<Void, Never>?
    @ObservationIgnored private var cooldown: [String: Date] = [:]
    @ObservationIgnored private var localBumps: [Date] = []
    @ObservationIgnored private var bumps = BumpDetector()
    @ObservationIgnored private let motion = CMMotionManager()
    private let log = Logger(subsystem: "app.nudge", category: "tap")

    public init(api: NudgeAPI) { self.api = api }

    public static var supportsUWB: Bool { NISession.deviceCapabilities.supportsPreciseDistanceMeasurement }

    // MARK: Lifecycle

    public func start() {
        guard !isRunning, me() != nil else { return }
        log.notice("tap service started, UWB=\(Self.supportsUWB)")
        isRunning = true
        let link = TapLink { [weak self] event in Task { @MainActor in self?.handle(event) } }
        self.link = link
        link.start()
        tokenTask = Task { [weak self] in await self?.keepTokenFresh() }
    }

    public func stop() {
        guard isRunning else { return }
        log.notice("tap service stopped")
        isRunning = false
        tokenTask?.cancel()
        link?.stop()
        link = nil
        for p in peers.values { p.ranging?.invalidate() }
        peers.removeAll()
        stopMotion()
        if case .near = phase { phase = .idle }
    }

    /// Clears the result card.
    public func dismiss() {
        switch phase {
        case .added, .failed: phase = .idle
        default: break
        }
    }

    // MARK: Token

    private func keepTokenFresh() async {
        while !Task.isCancelled {
            do {
                let t = try await api.tapToken()
                guard !Task.isCancelled, isRunning else { return }
                log.notice("tap token ready")
                token = t
                for key in peers.keys { sendHello(to: key) }
                // Swap for a new one a minute before it runs out.
                let wait = max(t.expiresAt.timeIntervalSinceNow - 60, 30)
                try? await Task.sleep(for: .seconds(wait))
            } catch {
                log.error("tap token: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func sendHello(to key: String) {
        guard let token, let me = me() else { return }
        var peer = peers[key] ?? Peer()
        if peer.ranging == nil, Self.supportsUWB { peer.ranging = RangingSession(key: key) { [weak self] key, d in self?.ranged(key, d) } }
        // The remote hello can arrive before our HTTP token and local ranging session.
        if !isFriend(peer.hello?.userId ?? ""), let remoteToken = peer.hello?.rangingToken {
            peer.ranging?.run(peerToken: remoteToken)
        }
        peers[key] = peer
        log.notice("tap sending hello, ranging=\(peer.ranging?.discoveryToken != nil)")
        link?.send(.hello(TapHello(userId: me, token: token.token, rangingToken: peer.ranging?.discoveryToken)), to: key)
    }

    // MARK: Link events

    private func handle(_ event: TapLink.Event) {
        guard isRunning else { return }
        switch event {
        case .connected(let key):
            sendHello(to: key)
        case .disconnected(let key):
            peers.removeValue(forKey: key)?.ranging?.invalidate()
            updateNear()
            updateMotion()
        case .received(let key, let data):
            guard let message = try? TapWire.decode(data) else { return }
            switch message {
            case .hello(let hello): received(hello, from: key)
            case .bump: receivedBump(from: key)
            }
        }
    }

    private func received(_ hello: TapHello, from key: String) {
        guard hello.userId != me() else { return }
        log.notice("tap received hello, alreadyFriend=\(self.isFriend(hello.userId)), ranging=\(hello.rangingToken != nil)")
        var peer = peers[key] ?? Peer()
        peer.hello = hello
        if isFriend(hello.userId) {
            // Already friends: stop measuring and never react to this phone.
            peer.ranging?.invalidate()
            peer.ranging = nil
        } else if let theirs = hello.rangingToken {
            peer.ranging?.run(peerToken: theirs)
        }
        peers[key] = peer
        updateMotion()
    }

    /// Peers that could become friends right now.
    private func eligible(_ key: String) -> Peer? {
        guard let peer = peers[key], let hello = peer.hello, !isFriend(hello.userId) else { return nil }
        if let until = cooldown[hello.userId], until > Date() { return nil }
        return peer
    }

    // MARK: Distance

    private func ranged(_ key: String, _ distance: Float?) {
        guard isRunning, eligible(key) != nil else { return }
        log.debug("tap distance \(distance ?? -1)")
        let touched = peers[key]?.tracker.add(distance: distance) ?? false
        if touched { tapped(key) } else { updateNear() }
    }

    private func updateNear() {
        guard !isBusy else { return }
        let best = peers.keys.compactMap { eligible($0)?.tracker.closeness }.max() ?? 0
        phase = best > 0.02 ? .near(closeness: best) : .idle
    }

    private var isBusy: Bool {
        switch phase {
        case .connecting, .added, .failed: true
        default: false
        }
    }

    // MARK: Bumps

    private func updateMotion() {
        let wanted = isRunning && peers.keys.contains { eligible($0) != nil }
        if wanted, !motion.isDeviceMotionActive, motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 100
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let a = data?.userAcceleration else { return }
                let magnitude = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
                MainActor.assumeIsolated { self?.motionSample(magnitude) }
            }
        } else if !wanted {
            stopMotion()
        }
    }

    private func stopMotion() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
    }

    private func motionSample(_ magnitude: Double) {
        let now = Date()
        guard bumps.add(magnitude: magnitude, at: now) else { return }
        localBumps = localBumps.filter { now.timeIntervalSince($0) < 2 } + [now]
        for key in peers.keys where eligible(key) != nil {
            link?.send(.bump, to: key)
            // Their bump may have arrived before ours registered.
            if let arrival = peers[key]?.lastBumpArrival, TapDetection.bumpsMatch(local: [now], arrival: arrival) { tapped(key) }
        }
    }

    private func receivedBump(from key: String) {
        let now = Date()
        peers[key]?.lastBumpArrival = now
        if eligible(key) != nil, TapDetection.bumpsMatch(local: localBumps, arrival: now) { tapped(key) }
    }

    // MARK: Tap

    private func tapped(_ key: String) {
        guard !isBusy, let hello = eligible(key)?.hello else { return }
        log.notice("tap detected; redeeming")
        cooldown[hello.userId] = Date().addingTimeInterval(TapDetection.cooldown)
        for k in peers.keys { peers[k]?.tracker.reset() }
        phase = .connecting
        redeemTask?.cancel()
        redeemTask = Task { [weak self] in await self?.redeem(hello.token) }
    }

    /// Asks until the other phone's tap lands too (about 8 s), then shows the result.
    private func redeem(_ token: String) async {
        let started = Date()
        // Let the bloom play before the card, even when the server is quick.
        let minimumBloom: TimeInterval = 0.9
        do {
            while Date().timeIntervalSince(started) < 8 {
                let result = try await api.tap(token: token)
                switch result.status {
                case .friends:
                    guard let user = result.user else { phase = .idle; return }
                    try? await Task.sleep(for: .seconds(max(minimumBloom - Date().timeIntervalSince(started), 0)))
                    phase = .added(user)
                    onAdded?(user)
                    return
                case .alreadyFriends:
                    // Nothing to do; let the bloom fade away.
                    phase = .idle
                    return
                case .pending:
                    try await Task.sleep(for: .milliseconds(600))
                }
            }
            phase = .failed("Didn't catch that. Hold your phones together again.")
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Previews

    public func preview(_ phase: Phase) { self.phase = phase }
}

/// One UWB ranging session with one peer. Each peer needs its own session (and its own discovery token).
@MainActor
final class RangingSession: NSObject, NISessionDelegate {
    let key: String
    private let session = NISession()
    private let onDistance: @MainActor (String, Float?) -> Void
    private var peerToken: NIDiscoveryToken?

    init(key: String, onDistance: @escaping @MainActor (String, Float?) -> Void) {
        self.key = key
        self.onDistance = onDistance
        super.init()
        session.delegate = self
        session.delegateQueue = .main
    }

    var discoveryToken: Data? {
        session.discoveryToken.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
    }

    func run(peerToken data: Data) {
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) else { return }
        peerToken = token
        session.run(NINearbyPeerConfiguration(peerToken: token))
    }

    func invalidate() { session.invalidate() }

    nonisolated func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        let distance = nearbyObjects.first?.distance
        MainActor.assumeIsolated { onDistance(key, distance) }
    }

    nonisolated func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        MainActor.assumeIsolated { onDistance(key, nil) }
    }

    nonisolated func sessionSuspensionEnded(_ session: NISession) {
        MainActor.assumeIsolated {
            if let peerToken { self.session.run(NINearbyPeerConfiguration(peerToken: peerToken)) }
        }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: any Error) {
        Logger(subsystem: "app.nudge", category: "tap").error("tap ranging invalidated: \(error.localizedDescription, privacy: .public)")
        MainActor.assumeIsolated { onDistance(key, nil) }
    }
}
