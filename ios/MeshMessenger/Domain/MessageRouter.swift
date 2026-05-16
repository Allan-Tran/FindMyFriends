import Foundation
import SwiftData
import Combine
@preconcurrency import MultipeerConnectivity

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

    /// Called when a chat message arrives for a DM UUID that wasn't pre-registered.
    /// DMStore sets this to create the conversation and subscribe to Firestore relay.
    var onIncomingDM: ((UUID, String) -> Void)?

    /// Called instead of the group relay when a DM message is sent.
    /// DMStore sets this to write to /dms/{dmId}/relay.
    var onDMRelaySend: ((MeshMessage, UUID) async -> Void)?

    /// Called whenever a chat message arrives for a real group (not a DM).
    /// GroupStore sets this to increment that group's unread count.
    var onIncomingGroupChat: ((UUID, String, Date) -> Void)?

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
        if dmIds.contains(groupId) {
            await onDMRelaySend?(envelope, groupId)
        } else if let uid = session.currentUid {
            await syncEngine.push(envelope: envelope, senderUid: uid)
        }
    }

    func ingest(_ envelope: MeshMessage, source: MessageSource) {
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
            if !dmIds.contains(envelope.groupId) {
                onIncomingGroupChat?(envelope.groupId, envelope.senderUsername, envelope.sentAt)
            }
        case .peerAnnounce:
            handlePeerAnnounce(envelope)
        case .groupSync:
            handleGroupSync(envelope)
        case .ack:
            break
        }
    }

    // MARK: MeshEngineDelegate

    nonisolated func meshEngine(_ engine: MeshEngine, didReceive envelope: MeshMessage) {
        Task { @MainActor in self.ingest(envelope, source: .mesh) }
    }

    nonisolated func meshEngine(_ engine: MeshEngine, didUpdateConnectedPeers peers: [MCPeerID]) {
        // could push events; UI binds to engine directly
    }

    // MARK: private

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
}
