import Foundation
import MultipeerConnectivity
import Combine

protocol MeshEngineDelegate: AnyObject, Sendable {
    func meshEngine(_ engine: MeshEngine, didReceive envelope: MeshMessage)
    func meshEngine(_ engine: MeshEngine, didUpdateConnectedPeers peers: [MCPeerID])
}

@MainActor
final class MeshEngine: NSObject, ObservableObject {
    @Published private(set) var connectedPeers: [MCPeerID] = []
    @Published private(set) var isRunning: Bool = false

    weak var delegate: MeshEngineDelegate?

    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var peerID: MCPeerID?

    private(set) var username: String = ""
    private var groupIds: Set<UUID> = []
    private let seenCache = SeenCache()

    func start(username: String, groupIds: Set<UUID>) {
        stop()
        self.username = username
        self.groupIds = groupIds
        let peer = PeerIdentity.peerID(for: username)
        self.peerID = peer

        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session

        var discoveryInfo: [String: String] = ["u": username]
        if !groupIds.isEmpty {
            discoveryInfo["g"] = groupIds.map { $0.meshPrefix }.sorted().joined(separator: ",")
        }
        let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: discoveryInfo, serviceType: AppConfig.multipeerServiceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: AppConfig.multipeerServiceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser

        isRunning = true
    }

    func updateGroups(_ ids: Set<UUID>) {
        guard isRunning, ids != groupIds else { return }
        start(username: username, groupIds: ids)
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil
        session?.disconnect()
        session?.delegate = nil
        session = nil
        connectedPeers = []
        isRunning = false
    }

    func broadcast(_ envelope: MeshMessage, excluding excluded: MCPeerID? = nil) {
        guard let session = session else { return }
        seenCache.insertIfNew(envelope.id)
        sendEnvelope(envelope, on: session, excluding: excluded)
    }

    private func sendEnvelope(_ envelope: MeshMessage, on session: MCSession, excluding excluded: MCPeerID?) {
        let peers = session.connectedPeers.filter { $0 != excluded }
        guard !peers.isEmpty else { return }
        do {
            let data = try MeshCodec.encoder.encode(envelope)
            try session.send(data, toPeers: peers, with: .reliable)
        } catch {
            #if DEBUG
            print("[Mesh] send error: \(error)")
            #endif
        }
    }

    private func hasOverlap(with otherPrefixes: String?) -> Bool {
        guard let raw = otherPrefixes, !raw.isEmpty else { return false }
        let theirs = Set(raw.split(separator: ",").map(String.init))
        let mine = Set(groupIds.map { $0.meshPrefix })
        return !theirs.intersection(mine).isEmpty
    }

    fileprivate func handleReceived(_ data: Data, from peer: MCPeerID) {
        guard let envelope = try? MeshCodec.decoder.decode(MeshMessage.self, from: data) else { return }
        guard groupIds.contains(envelope.groupId) else { return }
        guard seenCache.insertIfNew(envelope.id) else { return }

        delegate?.meshEngine(self, didReceive: envelope)

        if envelope.ttl > 1, envelope.messageType != .ack, let session = session {
            var forwarded = envelope
            forwarded.ttl -= 1
            sendEnvelope(forwarded, on: session, excluding: peer)
        }
    }
}

extension MeshEngine: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            self.connectedPeers = session.connectedPeers
            self.delegate?.meshEngine(self, didUpdateConnectedPeers: session.connectedPeers)
            if state == .connected {
                self.sendPeerAnnounce(to: peerID)
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.handleReceived(data, from: peerID)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { }
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) { }
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) { }

    private func sendPeerAnnounce(to peer: MCPeerID) {
        guard let session = session, let me = self.peerID else { return }
        let payload = PeerAnnouncePayload(peerId: me.displayName, username: username, groupIds: Array(groupIds))
        guard let payloadData = try? MeshCodec.encoder.encode(payload),
              let payloadString = String(data: payloadData, encoding: .utf8) else { return }
        for gid in groupIds {
            let env = MeshMessage(
                groupId: gid,
                originPeerId: me.displayName,
                senderUsername: username,
                content: payloadString,
                ttl: 1,
                messageType: .peerAnnounce
            )
            sendEnvelope(env, on: session, excluding: nil)
        }
    }
}

extension MeshEngine: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            let ctxString = context.flatMap { String(data: $0, encoding: .utf8) }
            let accept = self.hasOverlap(with: ctxString) || (ctxString == nil && !self.groupIds.isEmpty)
            invitationHandler(accept, accept ? self.session : nil)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        #if DEBUG
        print("[Mesh] advertiser failed: \(error)")
        #endif
    }
}

extension MeshEngine: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard let session = self.session else { return }
            let overlap = self.hasOverlap(with: info?["g"])
            guard overlap else { return }
            let context = self.groupIds.map { $0.meshPrefix }.sorted().joined(separator: ",").data(using: .utf8)
            browser.invitePeer(peerID, to: session, withContext: context, timeout: 15)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) { }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        #if DEBUG
        print("[Mesh] browser failed: \(error)")
        #endif
    }
}
