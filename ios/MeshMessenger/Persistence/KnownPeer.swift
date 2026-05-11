import Foundation
import SwiftData

@Model
final class KnownPeer {
    @Attribute(.unique) var compositeKey: String
    var peerId: String
    var username: String
    var groupId: UUID
    var lastSeenAt: Date

    init(peerId: String, username: String, groupId: UUID, lastSeenAt: Date = Date()) {
        self.peerId = peerId
        self.username = username
        self.groupId = groupId
        self.lastSeenAt = lastSeenAt
        self.compositeKey = "\(peerId)|\(groupId.uuidString)"
    }
}
