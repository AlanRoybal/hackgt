import Foundation
import MultipeerConnectivity
import os

/// The local link between phones with Nudge open (MultipeerConnectivity over Bluetooth / peer-to-peer Wi-Fi).
/// It only carries `TapWire` messages. Peers are named by a random per-launch key, so the main actor never
/// touches `MCPeerID`.
final class TapLink: NSObject, @unchecked Sendable {
    static let serviceType = "nudge-tap"

    enum Event: Sendable {
        case connected(String)
        case disconnected(String)
        case received(String, Data)
    }

    private let me: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let peers = OSAllocatedUnfairLock<[String: MCPeerID]>(uncheckedState: [:])
    private struct Discovery {
        var running = false
        var found: [String: MCPeerID] = [:]
        var lastInvite: [String: Date] = [:]
    }
    private let discovery = OSAllocatedUnfairLock(uncheckedState: Discovery())
    private var retryTask: Task<Void, Never>?
    private let onEvent: @Sendable (Event) -> Void
    private let log = Logger(subsystem: "app.nudge", category: "tap")

    init(onEvent: @escaping @Sendable (Event) -> Void) {
        me = MCPeerID(displayName: String(UUID().uuidString.prefix(12)))
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: nil, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType)
        self.onEvent = onEvent
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func start() {
        discovery.withLockUnchecked { $0.running = true }
        log.notice("tap discovery started")
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                self?.inviteAvailable()
            }
        }
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        discovery.withLockUnchecked { $0 = Discovery() }
        retryTask?.cancel()
        retryTask = nil
        log.notice("tap discovery stopped")
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        peers.withLockUnchecked { $0.removeAll() }
    }

    private func inviteAvailable() {
        let connected = peers.withLockUnchecked { Set($0.keys) }
        let targets = discovery.withLockUnchecked { d -> [MCPeerID] in
            guard d.running else { return [] }
            let now = Date()
            return d.found.values.filter { peer in
                let key = peer.displayName
                guard me.displayName < key, !connected.contains(key),
                      now.timeIntervalSince(d.lastInvite[key] ?? .distantPast) >= 22 else { return false }
                d.lastInvite[key] = now
                return true
            }
        }
        for peer in targets {
            log.notice("tap inviting nearby peer")
            browser.invitePeer(peer, to: session, withContext: nil, timeout: 20)
        }
    }

    /// Sends to one peer, or every connected peer when `key` is nil.
    func send(_ message: TapWire, to key: String? = nil) {
        let targets = peers.withLockUnchecked { p in key.map { p[$0].map { [$0] } ?? [] } ?? Array(p.values) }
        guard !targets.isEmpty, let data = try? message.encoded() else { return }
        do { try session.send(data, toPeers: targets, with: .reliable) } catch {
            log.error("tap send: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension TapLink: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let key = peerID.displayName
        log.notice("tap connection state \(state.rawValue)")
        switch state {
        case .connected:
            peers.withLockUnchecked { $0[key] = peerID }
            onEvent(.connected(key))
        case .notConnected:
            discovery.withLockUnchecked { $0.lastInvite.removeValue(forKey: key) }
            let known = peers.withLockUnchecked { $0.removeValue(forKey: key) != nil }
            if known { onEvent(.disconnected(key)) }
        default: break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        onEvent(.received(peerID.displayName, data))
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) {}
}

extension TapLink: MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        log.notice("tap found nearby peer")
        discovery.withLockUnchecked { $0.found[peerID.displayName] = peerID }
        inviteAvailable()
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        discovery.withLockUnchecked {
            $0.found.removeValue(forKey: peerID.displayName)
            $0.lastInvite.removeValue(forKey: peerID.displayName)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        log.notice("tap received invitation")
        invitationHandler(discovery.withLockUnchecked { $0.running }, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) {
        log.error("tap advertise: \(error.localizedDescription, privacy: .public)")
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
        log.error("tap browse: \(error.localizedDescription, privacy: .public)")
    }
}
