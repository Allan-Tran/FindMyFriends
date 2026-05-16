import Foundation
import SwiftData

@Model
final class LocalDMConversation: Identifiable {
    @Attribute(.unique) var id: UUID
    var myUsername: String
    var peerUsername: String
    var updatedAt: Date
    var unreadCount: Int = 0
    var lastReadAt: Date = Date()

    init(id: UUID, myUsername: String, peerUsername: String, updatedAt: Date = Date()) {
        self.id = id
        self.myUsername = myUsername
        self.peerUsername = peerUsername
        self.updatedAt = updatedAt
        self.unreadCount = 0
        self.lastReadAt = Date()
    }
}
