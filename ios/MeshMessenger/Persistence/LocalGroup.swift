import Foundation
import SwiftData

@Model
final class LocalGroup: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var adminId: String
    var inviteCode: String
    var createdAt: Date
    var memberUsernames: [String]
    var lastSyncedAt: Date?
    var unreadCount: Int = 0
    var lastReadAt: Date = Date()

    init(
        id: UUID,
        name: String,
        adminId: String,
        inviteCode: String,
        createdAt: Date,
        memberUsernames: [String] = [],
        lastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.adminId = adminId
        self.inviteCode = inviteCode
        self.createdAt = createdAt
        self.memberUsernames = memberUsernames
        self.lastSyncedAt = lastSyncedAt
        self.unreadCount = 0
        self.lastReadAt = Date()
    }
}
