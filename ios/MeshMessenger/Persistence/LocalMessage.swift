import Foundation
import SwiftData

@Model
final class LocalMessage: Identifiable {
    @Attribute(.unique) var id: UUID
    var groupId: UUID
    var senderUsername: String
    var content: String
    var sentAt: Date
    var receivedAt: Date
    var deliveryStatusRaw: String

    var deliveryStatus: DeliveryStatus {
        get { DeliveryStatus(rawValue: deliveryStatusRaw) ?? .pending }
        set { deliveryStatusRaw = newValue.rawValue }
    }

    var isLate: Bool {
        receivedAt.timeIntervalSince(sentAt) > AppConfig.lateMessageThreshold
    }

    init(
        id: UUID,
        groupId: UUID,
        senderUsername: String,
        content: String,
        sentAt: Date,
        receivedAt: Date = Date(),
        deliveryStatus: DeliveryStatus = .pending
    ) {
        self.id = id
        self.groupId = groupId
        self.senderUsername = senderUsername
        self.content = content
        self.sentAt = sentAt
        self.receivedAt = receivedAt
        self.deliveryStatusRaw = deliveryStatus.rawValue
    }
}
