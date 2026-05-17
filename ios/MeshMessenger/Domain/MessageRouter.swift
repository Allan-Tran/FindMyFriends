import Foundation
import SwiftData
import Combine
import UIKit
@preconcurrency import MultipeerConnectivity
import CoreBluetooth

enum MessageSource: Sendable {
    case mesh
    case relay
    case local
}

@MainActor
final class MessageRouter: ObservableObject, MeshEngineDelegate {
    @Published private(set) var activeGroupIds: Set<UUID> = []
    private var realGroupIds: Set<UUID> = []
    private var dmIds: Set<UUID> = []
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var processedMessageIds: Set<UUID> = []

    /// Called when a chat message arrives for a DM UUID that wasn't pre-registered.
    /// DMStore sets this to create the conversation and subscribe to Firestore relay.
    var onIncomingDM: ((UUID, String) -> Void)?

    /// Called instead of the group relay when a DM message is sent.
    /// DMStore sets this to write to /dms/{dmId}/relay.
    var onDMRelaySend: ((MeshMessage, UUID) async -> Void)?

    /// Called whenever a chat message arrives for a real group (not a DM).
    /// GroupStore sets this to increment that group's unread count.
    var onIncomingGroupChat: ((UUID, String, Date, String) -> Void)?

    /// Called whenever a chat message arrives for a DM conversation.
    /// DMStore sets this to post a local notification when the conversation isn't active.
    var onIncomingDMChat: ((UUID, String, Date, String) -> Void)?

    let meshEngine: MeshEngine
    let proximityEngine: ProximityEngine
    let syncEngine: SyncEngine
    private let messageRepository: MessageRepository
    private let peerRepository: KnownPeerRepository
    private let session: AuthSession

    init(
        session: AuthSession,
        meshEngine: MeshEngine,
        proximityEngine: ProximityEngine,
        syncEngine: SyncEngine,
        messageRepository: MessageRepository,
        peerRepository: KnownPeerRepository
    ) {
        self.session = session
        self.meshEngine = meshEngine
        self.proximityEngine = proximityEngine
        self.syncEngine = syncEngine
        self.messageRepository = messageRepository
        self.peerRepository = peerRepository
        meshEngine.delegate = self
        syncEngine.attach(router: self)
        
        proximityEngine.delegate = self
        setupBackgroundLifecycleObservers()
    }

    func start(username: String, groupIds: Set<UUID>) {
        realGroupIds = groupIds
        let all = groupIds.union(dmIds)
        activeGroupIds = all
        meshEngine.start(username: username, groupIds: all)
        proximityEngine.start(localIdentity: username)
        syncEngine.start()
        syncEngine.updateActiveGroups(realGroupIds)   // DM IDs are mesh-only; never relay
    }

    func updateActiveGroups(_ ids: Set<UUID>) {
        realGroupIds = ids
        let all = ids.union(dmIds)
        activeGroupIds = all
        meshEngine.updateGroups(all)
        syncEngine.updateActiveGroups(realGroupIds)   // DM IDs are mesh-only; never relay
    }

    /// Register a DM conversation UUID so the mesh layer routes it — no Firestore relay.
    func registerDM(_ id: UUID) {
        guard !dmIds.contains(id) else { return }
        dmIds.insert(id)
        let all = realGroupIds.union(dmIds)
        activeGroupIds = all
        if meshEngine.isRunning { meshEngine.updateGroups(all) }
        // Intentionally NOT updating syncEngine — DMs have no Firestore group document.
    }

    func stop() {
        meshEngine.stop()
        proximityEngine.stop()
        syncEngine.stop()
        activeGroupIds = []
    }

    func pauseMesh() {
        meshEngine.stop()
        proximityEngine.stop()
    }

    func resumeMesh() {
        guard let username = session.currentUsername else { return }
        let all = realGroupIds.union(dmIds)
        activeGroupIds = all
        meshEngine.start(username: username, groupIds: all)
        proximityEngine.start(localIdentity: username)
    }

    /// Mesh-only send — never touches the Firebase relay.
    /// Used for large payloads (e.g. inline image data) that must not be
    /// written to Firestore. TTL=1 prevents multi-hop flooding.
    func sendMeshOnly(content: String, to groupId: UUID) async {
        guard let username = session.currentUsername else { return }
        let envelope = MeshMessage(
            groupId: groupId,
            originPeerId: username,
            senderUsername: username,
            content: content,
            ttl: 1,
            messageType: .chat
        )
        persist(envelope, status: .sent)
        meshEngine.broadcast(envelope)
    }

    func sendChat(content: String, to groupId: UUID) async {
        guard let username = session.currentUsername else { return }
        let envelope = MeshMessage(
            groupId: groupId,
            originPeerId: username,
            senderUsername: username,
            content: content,
            messageType: .chat
        )
        persist(envelope, status: .sent)
        meshEngine.broadcast(envelope)
        // Also push via BLE so backgrounded peers receive messages even when MCSession is suspended.
        if let data = try? MeshCodec.encoder.encode(envelope) {
            proximityEngine.broadcastMessageData(data)
        }
        if dmIds.contains(groupId) {
            await onDMRelaySend?(envelope, groupId)
        } else if let uid = session.currentUid {
            await syncEngine.push(envelope: envelope, senderUid: uid)
        }
    }

    func ingest(_ envelope: MeshMessage, source: MessageSource) {
        guard !processedMessageIds.contains(envelope.id) else { return }
            processedMessageIds.insert(envelope.id)
            if processedMessageIds.count > 1000 { processedMessageIds.removeAll() }
        if !activeGroupIds.contains(envelope.groupId) {
            // Auto-detect an incoming DM from a contact who messaged us first.
            guard envelope.messageType == .chat,
                  let myUsername = session.currentUsername,
                  !envelope.senderUsername.isEmpty,
                  DMStore.conversationId(userA: myUsername, userB: envelope.senderUsername) == envelope.groupId
            else { return }
            registerDM(envelope.groupId)
            onIncomingDM?(envelope.groupId, envelope.senderUsername)
        }
        switch envelope.messageType {
        case .chat:
            persist(envelope, status: .delivered)
            if dmIds.contains(envelope.groupId) {
                onIncomingDMChat?(envelope.groupId, envelope.senderUsername, envelope.sentAt, envelope.content)
            } else {
                onIncomingGroupChat?(envelope.groupId, envelope.senderUsername, envelope.sentAt, envelope.content)
            }
        case .peerAnnounce:
            handlePeerAnnounce(envelope)
        case .groupSync:
            handleGroupSync(envelope)
        case .ack:
            break
        }
    }

    // MARK: - MeshEngineDelegate

    nonisolated func meshEngine(_ engine: MeshEngine, didReceive envelope: MeshMessage) {
        Task { @MainActor in
            self.ingest(envelope, source: .mesh)
        }
    }

    nonisolated func meshEngine(_ engine: MeshEngine, didUpdateConnectedPeers peers: [MCPeerID]) {
            // 1. Evaluate the collection state synchronously on the background thread
            let hasConnectedPeers = !peers.isEmpty
            
            Task { @MainActor in
                // 2. Safely capture and pass only the Sendable Bool into the Main Actor
                if hasConnectedPeers {
                    self.retryPendingMessagesAcrossActiveGroups()
                }
            }
        }

    // MARK: - Private Core Logic

    private func persist(_ envelope: MeshMessage, status: DeliveryStatus) {
        let local = LocalMessage(
            id: envelope.id,
            groupId: envelope.groupId,
            senderUsername: envelope.senderUsername,
            content: envelope.content,
            sentAt: envelope.sentAt,
            receivedAt: Date(),
            deliveryStatus: status
        )
        try? messageRepository.upsert(local)
    }

    func broadcastGroupSync(groupId: UUID, memberUsernames: [String]) {
        guard let username = session.currentUsername else { return }
        let payload = GroupSyncPayload(groupId: groupId, memberUsernames: memberUsernames)
        guard let payloadData = try? MeshCodec.encoder.encode(payload),
              let payloadString = String(data: payloadData, encoding: .utf8) else { return }
        let envelope = MeshMessage(
            groupId: groupId,
            originPeerId: username,
            senderUsername: username,
            content: payloadString,
            ttl: AppConfig.defaultMessageTTL,
            messageType: .groupSync
        )
        meshEngine.broadcast(envelope)
    }

    private func handlePeerAnnounce(_ envelope: MeshMessage) {
        guard let data = envelope.content.data(using: .utf8),
              let payload = try? MeshCodec.decoder.decode(PeerAnnouncePayload.self, from: data) else { return }
        for gid in payload.groupIds where activeGroupIds.contains(gid) {
            try? peerRepository.touch(peerId: payload.peerId, username: payload.username, groupId: gid)
        }
    }

    private func handleGroupSync(_ envelope: MeshMessage) {
        guard let data = envelope.content.data(using: .utf8),
              let payload = try? MeshCodec.decoder.decode(GroupSyncPayload.self, from: data) else { return }
        guard activeGroupIds.contains(payload.groupId) else { return }
        for username in payload.memberUsernames {
            try? peerRepository.touch(peerId: username, username: username, groupId: payload.groupId)
        }
    }
    
    private func retryPendingMessagesAcrossActiveGroups() {
        for groupId in activeGroupIds {
            guard let undeliveredMessages = try? messageRepository.pendingMessages(in: groupId) else { continue }
            
            for localMsg in undeliveredMessages {
                let envelope = MeshMessage(
                    id: localMsg.id,
                    groupId: localMsg.groupId,
                    originPeerId: localMsg.senderUsername,
                    senderUsername: localMsg.senderUsername,
                    content: localMsg.content,
                    sentAt: localMsg.sentAt,
                    ttl: AppConfig.defaultMessageTTL,
                    messageType: .chat
                )
                meshEngine.broadcast(envelope)
            }
        }
    }

    // MARK: - Background Lifecycle Management

    private func setupBackgroundLifecycleObservers() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleDidEnterBackground() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleWillEnterForeground() }
        }
    }

    private func handleDidEnterBackground() {
        self.backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "MeshMessengerSocketFlush") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
        
        retryPendingMessagesAcrossActiveGroups()
        
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run {
                self.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        if backgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
    }

    private func handleWillEnterForeground() {
        endBackgroundTask()
        retryPendingMessagesAcrossActiveGroups()
    }
}

// MARK: - ProximityEngineDelegate

extension MessageRouter: ProximityEngineDelegate {
    func proximityEngine(_ engine: ProximityEngine, didDiscoverUsername username: String, peripheral: CBPeripheral) {
        for groupId in activeGroupIds {
            if dmIds.contains(groupId) {
                guard let myUsername = session.currentUsername,
                      DMStore.conversationId(userA: myUsername, userB: username) == groupId else { continue }
            }
            
            guard let pending = try? messageRepository.pendingMessages(in: groupId) else { continue }
            
            for localMsg in pending {
                let envelope = MeshMessage(
                    id: localMsg.id,
                    groupId: localMsg.groupId,
                    originPeerId: localMsg.senderUsername,
                    senderUsername: localMsg.senderUsername,
                    content: localMsg.content,
                    sentAt: localMsg.sentAt,
                    ttl: 1,
                    messageType: .chat
                )
                
                if let data = try? MeshCodec.encoder.encode(envelope) {
                    engine.writeMessageData(data, to: peripheral)
                }
            }
        }
    }

    func proximityEngine(_ engine: ProximityEngine, didReceiveMessageData data: Data) {
        guard let envelope = try? MeshCodec.decoder.decode(MeshMessage.self, from: data) else { return }
        self.ingest(envelope, source: .mesh)
    }
}
