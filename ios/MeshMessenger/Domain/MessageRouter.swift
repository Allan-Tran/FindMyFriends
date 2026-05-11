import Foundation
import SwiftData
import Combine
import MultipeerConnectivity

enum MessageSource: Sendable {
    case mesh
    case relay
    case local
}

@MainActor
final class MessageRouter: ObservableObject, MeshEngineDelegate {
    @Published private(set) var activeGroupIds: Set<UUID> = []

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
        activeGroupIds = groupIds
        meshEngine.start(username: username, groupIds: groupIds)
        proximityEngine.start(localIdentity: username)
        syncEngine.start()
    }

    func updateActiveGroups(_ ids: Set<UUID>) {
        activeGroupIds = ids
        meshEngine.updateGroups(ids)
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
        await syncEngine.push(envelope: envelope)
    }

    func ingest(_ envelope: MeshMessage, source: MessageSource) {
        guard activeGroupIds.contains(envelope.groupId) else { return }
        switch envelope.messageType {
        case .chat:
            persist(envelope, status: source == .relay ? .delivered : .delivered)
        case .peerAnnounce:
            handlePeerAnnounce(envelope)
        case .groupSync:
            break
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

    private func handlePeerAnnounce(_ envelope: MeshMessage) {
        guard let data = envelope.content.data(using: .utf8),
              let payload = try? MeshCodec.decoder.decode(PeerAnnouncePayload.self, from: data) else { return }
        for gid in payload.groupIds where activeGroupIds.contains(gid) {
            try? peerRepository.touch(peerId: payload.peerId, username: payload.username, groupId: gid)
        }
    }
}
