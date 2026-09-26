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
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        peers.withLockUnchecked { $0.removeAll() }
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
        switch state {
        case .connected:
            peers.withLockUnchecked { $0[key] = peerID }
            onEvent(.connected(key))
        case .notConnected:
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
        // Both phones see each other; only the one with the smaller key invites, so there's one connection.
        guard me.displayName < peerID.displayName else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) {
        log.error("tap advertise: \(error.localizedDescription, privacy: .public)")
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
        log.error("tap browse: \(error.localizedDescription, privacy: .public)")
    }
}
