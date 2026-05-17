import Foundation
@preconcurrency import MultipeerConnectivity
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
    private let reconnectManager = ReconnectManager()
    private var heartbeatTask: Task<Void, Never>?

    func start(username: String, groupIds: Set<UUID>) {
        stop()
        self.username = username
        self.groupIds = groupIds
        let peer = PeerIdentity.peerID(for: username)
        self.peerID = peer

        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session

        startAdvertisingAndBrowsing(peer: peer, groupIds: groupIds)
        startHeartbeatLoop()
        isRunning = true
    }

    private func startAdvertisingAndBrowsing(peer: MCPeerID, groupIds: Set<UUID>) {
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
    }

    func updateGroups(_ ids: Set<UUID>) {
        // FIX: Stop tearing down the entire MCSession socket when group scopes adjust.
        guard isRunning, ids != groupIds else { return }
        self.groupIds = ids
        
        // Cycle only the local advertisement headers with the updated discovery arrays
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
        
        if let peer = self.peerID {
            var discoveryInfo: [String: String] = ["u": username]
            if !ids.isEmpty {
                discoveryInfo["g"] = ids.map { $0.meshPrefix }.sorted().joined(separator: ",")
            }
            let newAdvertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: discoveryInfo, serviceType: AppConfig.multipeerServiceType)
            newAdvertiser.delegate = self
            newAdvertiser.startAdvertisingPeer()
            self.advertiser = newAdvertiser
        }
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reconnectManager.cancelAll()
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

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000) // 8s keepalive — frequent enough to prevent MCSession idle teardown
                guard let self = self else { return }
                
                await MainActor.run {
                    guard let session = self.session, !session.connectedPeers.isEmpty else { return }
                    if let primaryGroup = self.groupIds.first {
                        let ping = MeshMessage(
                            groupId: primaryGroup,
                            originPeerId: self.username,
                            senderUsername: self.username,
                            content: "",
                            ttl: 1,
                            messageType: .ack
                        )
                        self.sendEnvelope(ping, on: session, excluding: nil)
                    }
                }
            }
        }
    }

    fileprivate func handleReceived(_ data: Data, from peer: MCPeerID) {
        guard let envelope = try? MeshCodec.decoder.decode(MeshMessage.self, from: data) else { return }
        
        // FIX: Allow inbound fallback DMs from unexpected users to bypass early filtering
        let isPotentialDM = envelope.messageType == .chat && !envelope.senderUsername.isEmpty
        guard groupIds.contains(envelope.groupId) || isPotentialDM else { return }
        
        guard seenCache.insertIfNew(envelope.id) else { return }

        delegate?.meshEngine(self, didReceive: envelope)

        // Only forward messages downstream if we actively track the group channel string
        if groupIds.contains(envelope.groupId), envelope.ttl > 1, envelope.messageType != .ack, let session = session {
            var forwarded = envelope
            forwarded.ttl -= 1
            sendEnvelope(forwarded, on: session, excluding: peer)
        }
    }
}

// MARK: - MCSessionDelegate

extension MeshEngine: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            self.connectedPeers = session.connectedPeers
            self.delegate?.meshEngine(self, didUpdateConnectedPeers: session.connectedPeers)
            switch state {
            case .connected:
                self.reconnectManager.didConnect(to: peerID)
                self.sendPeerAnnounce(to: peerID)
            case .notConnected:
                guard let browser = self.browser, let mcSession = self.session else { return }
                let context = self.groupIds.map { $0.meshPrefix }.sorted().joined(separator: ",").data(using: .utf8)
                self.reconnectManager.scheduleReconnect(to: peerID, via: browser, on: mcSession, context: context)
            default:
                break
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

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MeshEngine: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        nonisolated(unsafe) let handler = invitationHandler
        Task { @MainActor in
            // Accept invitations globally from any node running our service type descriptor.
            // Data routing and structural filters are completely handled inside MessageRouter.ingest().
            handler(true, self.session)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        #if DEBUG
        print("[Mesh] advertiser failed: \(error)")
        #endif
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MeshEngine: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard let session = self.session else { return }
            
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
