import Foundation

enum MeshMessageType: String, Codable, Sendable {
    case chat
    case ack
    case peerAnnounce
    case groupSync
}

struct MeshMessage: Codable, Sendable, Hashable {
    let id: UUID
    let groupId: UUID
    let originPeerId: String
    let senderUsername: String
    let content: String
    let sentAt: Date
    var ttl: Int
    let messageType: MeshMessageType

    init(
        id: UUID = UUID(),
        groupId: UUID,
        originPeerId: String,
        senderUsername: String,
        content: String,
        sentAt: Date = Date(),
        ttl: Int = AppConfig.defaultMessageTTL,
        messageType: MeshMessageType = .chat
    ) {
        self.id = id
        self.groupId = groupId
        self.originPeerId = originPeerId
        self.senderUsername = senderUsername
        self.content = content
        self.sentAt = sentAt
        self.ttl = ttl
        self.messageType = messageType
    }
}

struct PeerAnnouncePayload: Codable, Sendable {
    let peerId: String
    let username: String
    let groupIds: [UUID]
}

struct GroupSyncPayload: Codable, Sendable {
    let groupId: UUID
    let memberUsernames: [String]
}

struct AckPayload: Codable, Sendable {
    let messageId: UUID
}

enum MeshCodec {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
